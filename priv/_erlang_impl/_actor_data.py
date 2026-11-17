import asyncio
from collections.abc import Callable
from dataclasses import dataclass
from threading import local
from typing import Literal, Protocol, Self, runtime_checkable

import erlang

from ._actor_common import _owned_wait, _result


@runtime_checkable
class DataDispatcher(Protocol):
    async def dispatch(self, payload: bytes, /) -> bytes: ...


class ActorOverloaded(RuntimeError):
    pass


class ActorAdmissionClosed(RuntimeError):
    pass


class ActorRestarting(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class ActorInfo:
    pid: str
    generation: int
    admitted_count: int
    admitted_bytes: int


@dataclass(frozen=True, slots=True)
class ContextCounts:
    created: int
    destroyed: int

    @property
    def live(self) -> int:
        return self.created - self.destroyed


async def context_counts() -> ContextCounts:
    result = _result(await erlang.async_call("_actor_context_counts"))
    if not isinstance(result, tuple) or len(result) != 2:
        raise RuntimeError("Invalid native context counters", result)
    created, destroyed = result
    if type(created) is not int or type(destroyed) is not int:
        raise RuntimeError("Invalid native context counters", result)
    return ContextCounts(created, destroyed)


def checked(reply: object) -> object:
    if isinstance(reply, tuple) and len(reply) == 2 and reply[0] == "error":
        value = reply[1]
        if value == "restarting":
            raise ActorRestarting("Actor is restarting")
        if (
            isinstance(value, tuple)
            and len(value) == 3
            and value[0] == "generation_changed"
        ):
            _, expected, current = value
            if type(expected) is int and type(current) is int:
                raise ActorGenerationChanged(expected, current)
    return _result(reply)


class ActorGenerationChanged(RuntimeError):
    def __init__(self, expected: int, current: int) -> None:
        super().__init__("Actor generation changed", expected, current)
        self.expected = expected
        self.current = current


def arguments(state: object, ticket: object, payload: bytes) -> object:
    return erlang._actor_retain((erlang._actor_unwrap(state), ticket, payload))


def portable(value: object) -> object:
    return erlang._actor_retain(erlang._actor_unwrap(value))


def initialize(factory: object, state: object) -> None:
    erlang._actor_construct(state, factory)


def call(state: object, ticket: object, payload: bytes) -> bytes:
    try:
        container = erlang._actor_unwrap(state)
        if not isinstance(container, DataDispatcher):
            raise TypeError("Actor factory must return a data dispatcher")
    except BaseException:
        erlang._actor_complete(ticket)
        raise
    return dispatch_worker(container, ticket, payload)


def response(value: object) -> bytes:
    result = erlang._actor_unwrap(value)
    if not isinstance(result, bytes):
        raise TypeError("Actor response must be bytes")
    return result


async def dispatch(container: DataDispatcher, ticket: object, payload: bytes) -> bytes:
    try:
        result = await container.dispatch(payload)
        if type(result) is not bytes:
            raise TypeError("Actor dispatch must return immutable bytes")
        return result
    finally:
        erlang._actor_complete(ticket)


class _WorkerLoop(local):
    def __init__(self) -> None:
        self.loop: asyncio.AbstractEventLoop | None = None

    def get(self) -> asyncio.AbstractEventLoop:
        if self.loop is None:
            self.loop = asyncio.new_event_loop()
        return self.loop


_worker_loop = _WorkerLoop()


def dispatch_worker(container: DataDispatcher, ticket: object, payload: bytes) -> bytes:
    return _worker_loop.get().run_until_complete(dispatch(container, ticket, payload))


def close_worker_loop() -> None:
    loop = _worker_loop.loop
    if loop is not None:
        loop.close()
        _worker_loop.loop = None


def _resolved(reply: object) -> tuple[object, int, object]:
    result = _result(reply)
    if not isinstance(result, tuple) or len(result) != 3:
        raise RuntimeError("Invalid actor resolution", result)
    pid, generation, gate = result
    if not isinstance(generation, int):
        raise RuntimeError("Invalid actor generation", generation)
    return pid, generation, gate


class DataTicket:
    def __init__(self, pid: object, gate: object, payload: bytes) -> None:
        if type(payload) is not bytes:
            raise TypeError("Actor requests must be immutable encoded bytes")
        self._pid = pid
        self._gate = gate
        self._payload = payload
        self._ticket = erlang._actor_reserve(gate, len(payload))

    def abort(self) -> None:
        erlang._actor_abort(self._ticket)

    async def send(self) -> bytes:
        try:
            result = _result(
                await erlang.async_call(
                    "_actor_data_call",
                    self._pid,
                    self._gate,
                    self._ticket,
                    self._payload,
                )
            )
            if not isinstance(result, bytes):
                raise RuntimeError("Invalid actor byte response", result)
            return result
        finally:
            # Only provably uncommitted work can be released here. A queued
            # late callback sees the resource's aborted state and cannot run.
            self.abort()


class DataActorRef:
    def __init__(
        self, group: object, child_id: str, pid: object, generation: int, gate: object
    ) -> None:
        self._group = group
        self.child_id = child_id
        self._pid = pid
        self.generation = generation
        self._gate = gate

    @property
    def pid(self) -> object:
        return self._pid

    def reserve(self, payload: bytes, /) -> DataTicket:
        return DataTicket(self._pid, self._gate, payload)

    async def rejoin(self) -> Self:
        pid, generation, gate = _resolved(
            (
                "ok",
                checked(
                    await erlang.async_call(
                        "_actor_group_resolve", self._group, self.child_id
                    )
                ),
            )
        )
        return type(self)(self._group, self.child_id, pid, generation, gate)

    async def info(self) -> ActorInfo:
        result = checked(
            await erlang.async_call(
                "_actor_group_info", self._group, self.child_id, self.generation
            )
        )
        if not isinstance(result, tuple) or len(result) != 4:
            raise RuntimeError("Invalid native actor information", result)
        pid, generation, count, size = result
        if (
            not isinstance(pid, bytes)
            or type(generation) is not int
            or type(count) is not int
            or type(size) is not int
        ):
            raise RuntimeError("Invalid native actor information", result)
        return ActorInfo(pid.decode("ascii"), generation, count, size)

    async def crash(self) -> None:
        """Kill exactly this generation and wait for its running body to drain."""
        pending = asyncio.create_task(
            erlang.async_call(
                "_actor_group_crash", self._group, self.child_id, self.generation
            )
        )
        checked(await _owned_wait(pending))

    async def call(self, payload: bytes, /) -> bytes:
        current = await self.rejoin()
        if current.generation != self.generation:
            raise ActorGenerationChanged(self.generation, current.generation)
        ticket = self.reserve(payload)
        return await ticket.send()


class DataActorGroup:
    def __init__(self, *, max_children: int = 64) -> None:
        if max_children <= 0:
            raise ValueError("max_children must be positive")
        self._max_children = max_children
        self._group: object | None = None

    async def __aenter__(self) -> Self:
        if self._group is not None:
            raise RuntimeError("Group is already open")
        pending = asyncio.create_task(
            erlang.async_call("_actor_group_open", self._max_children)
        )
        try:
            self._group = _result(await _owned_wait(pending))
        except asyncio.CancelledError:
            self._group = _result(pending.result())
            await self.close()
            raise
        return self

    async def spawn(
        self,
        child_id: str,
        factory: Callable[[], DataDispatcher],
        *,
        capacity: int = 64,
        max_bytes: int = 1048576,
        restart: Literal["permanent", "transient", "temporary"] = "permanent",
    ) -> DataActorRef:
        if self._group is None:
            raise RuntimeError("Group is not open")
        if capacity <= 0 or max_bytes <= 0:
            raise ValueError("Actor mailbox bounds must be positive")
        pending = asyncio.create_task(
            erlang.async_call(
                "_actor_group_spawn",
                self._group,
                child_id,
                erlang._actor_retain(factory),
                capacity,
                max_bytes,
                restart,
            )
        )
        pid, generation, gate = _resolved(await _owned_wait(pending))
        return DataActorRef(self._group, child_id, pid, generation, gate)

    async def stop(self, child_id: str, /) -> None:
        if self._group is None:
            raise RuntimeError("Group is not open")
        pending = asyncio.create_task(
            erlang.async_call("_actor_group_stop", self._group, child_id)
        )
        _result(await _owned_wait(pending))

    async def close(self) -> None:
        if self._group is not None:
            pending = asyncio.create_task(
                erlang.async_call("_actor_group_close", self._group)
            )
            await _owned_wait(pending)
            self._group = None

    async def __aexit__(self, *exc: object) -> None:
        await self.close()

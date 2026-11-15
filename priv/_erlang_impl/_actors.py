import asyncio
from collections.abc import Awaitable, Callable
from typing import Literal

import erlang


async def _outcome(awaitable: Awaitable[object]) -> tuple[bool, object]:
    try:
        return True, await awaitable
    except BaseException as error:
        return False, error


def _result(reply: object) -> object:
    if not isinstance(reply, tuple) or len(reply) != 2:
        raise RuntimeError("Invalid native actor response", reply)
    status, value = reply
    if status == "ok":
        return value
    if status == "error" and isinstance(value, tuple):
        return _result(value)
    if status == "python_error":
        error = erlang._actor_unwrap(value)
        if isinstance(error, BaseException):
            raise error
    raise RuntimeError("Native actor operation failed", reply)


async def _owned_wait[T](pending: asyncio.Task[T]) -> T:
    cancelled: asyncio.CancelledError | None = None
    while not pending.done():
        try:
            await asyncio.shield(pending)
        except asyncio.CancelledError as error:
            cancelled = error
    result = pending.result()
    if cancelled is not None:
        raise cancelled
    return result


class OwnedActor:
    def __init__(self, pid: object, methods: tuple[object, ...]) -> None:
        self._pid = pid
        self._methods = methods
        self._stopped = False
        self._stopping: asyncio.Task[None] | None = None

    async def call(
        self,
        index: int,
        method: object,
        /,
        *args: object,
        **kwargs: object,
    ) -> object:
        if self._stopped or self._stopping is not None:
            raise RuntimeError("Actor is stopped")
        if erlang._actor_unwrap(self._methods[index]) is not method:
            raise ValueError("The method does not match its native registration")
        reply = await erlang.async_call(
            "_actor_call",
            self._pid,
            self._methods[index],
            erlang._actor_retain(args),
            erlang._actor_retain(kwargs),
        )
        return erlang._actor_unwrap(_result(reply))

    async def _stop(self) -> None:
        await erlang.async_call("_actor_stop", self._pid)
        self._stopped = True
        self._methods = ()

    async def stop(self) -> None:
        if self._stopping is None:
            self._stopping = asyncio.create_task(self._stop())
        await _owned_wait(self._stopping)


async def spawn(
    factory: Callable[[], object],
    methods: tuple[Callable[..., Awaitable[object]], ...],
    *,
    mailbox: Literal["unbounded"],
) -> OwnedActor:
    retained = tuple(erlang._actor_retain(method) for method in methods)
    pending = asyncio.create_task(
        erlang.async_call(
            "_actor_spawn",
            erlang._actor_retain(factory),
            list(retained),
            mailbox,
        )
    )
    try:
        pid = _result(await _owned_wait(pending))
    except asyncio.CancelledError:
        pid = _result(pending.result())
        actor = OwnedActor(pid, retained)
        await actor.stop()
        raise
    return OwnedActor(pid, retained)

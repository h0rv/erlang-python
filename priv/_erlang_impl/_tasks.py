import asyncio
import threading
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Literal, assert_never, final

import erlang

from _erlang_impl._actor_common import _result

type Outcome = tuple[Literal[True], bytes] | tuple[Literal[False], BaseException]


@dataclass(frozen=True, slots=True)
class _Running:
    loop: asyncio.AbstractEventLoop
    task: asyncio.Task[object]


@final
class Body:
    def __init__(self, invoke: Callable[[bytes], Awaitable[bytes]]) -> None:
        self._invoke = invoke
        self._lock = threading.Lock()
        self._cancelled = False
        self._state: Literal["ready", "sealed", "finished"] | _Running = "ready"

    def cancel(self) -> None:
        with self._lock:
            if self._cancelled:
                return
            self._cancelled = True
            if isinstance(self._state, _Running):
                self._state.loop.call_soon_threadsafe(self._state.task.cancel)

    def seal(self) -> bool:
        with self._lock:
            match self._state:
                case "ready" | "sealed":
                    self._state = "sealed"
                    self._cancelled = True
                    return True
                case _Running() | "finished":
                    return False
                case unexpected:
                    assert_never(unexpected)

    async def run(self, payload: bytes) -> bytes:
        task = asyncio.current_task()
        if task is None:
            raise RuntimeError("Native task execution requires a running Python task")
        with self._lock:
            match self._state:
                case "ready":
                    self._state = _Running(asyncio.get_running_loop(), task)
                    cancelled = self._cancelled
                case "sealed":
                    raise asyncio.CancelledError
                case _Running() | "finished":
                    raise RuntimeError("A task body cannot be reused")
                case unexpected:
                    assert_never(unexpected)
        try:
            if cancelled:
                raise asyncio.CancelledError
            return await self._invoke(payload)
        finally:
            with self._lock:
                self._state = "finished"


async def execute(body: Body, ticket: object, payload: bytes) -> bytes:
    try:
        return await body.run(payload)
    finally:
        erlang._actor_complete(ticket)


def request_cancel(reference: object) -> None:
    body = erlang._actor_unwrap(reference)
    if not isinstance(body, Body):
        raise TypeError("Invalid task body")
    body.cancel()


def seal(reference: object) -> bool:
    body = erlang._actor_unwrap(reference)
    if type(body) is not Body:
        raise TypeError("Invalid task body")
    return body.seal()


class UncertainInflight(RuntimeError):
    pass


def result(reply: object) -> object:
    if isinstance(reply, tuple) and len(reply) == 2:
        status, value = reply
        if status == "error" and isinstance(value, tuple) and value[0] == "uncertain_inflight":
            raise UncertainInflight(value)
    return _result(reply)


async def open_group(count: int, max_bytes: int) -> tuple[object, object]:
    value = result(await erlang.async_call("_task_open", count, max_bytes))
    if not isinstance(value, tuple) or len(value) != 2:
        raise RuntimeError("Invalid task group", value)
    return value


async def start(group: object, gate: object, factory: Callable[[], Body], payload: bytes) -> object:
    ticket = erlang._actor_reserve(gate, len(payload))
    try:
        return result(
            await erlang.async_call(
                "_task_start", group, gate, ticket, payload, erlang._actor_retain(factory)
            )
        )
    finally:
        erlang._actor_abort(ticket)


async def outcome(group: object, pid: object) -> Outcome:
    reply = await erlang.async_call("_task_wait", group, pid)
    try:
        value = result(reply)
        if not isinstance(value, bytes):
            raise RuntimeError("Invalid task result", value)
        return True, value
    except BaseException as error:
        return False, error


async def cancel(group: object, pid: object) -> None:
    """Request only. A CancelledError outcome acknowledges completion; uncertainty does not."""
    value = await erlang.async_call("_task_cancel", group, pid)
    if value != "ok":
        result(value)


async def shutdown(group: object, milliseconds: int) -> None:
    value = await erlang.async_call("_task_shutdown", group, milliseconds)
    if value != "ok":
        result(value)


async def dispose(group: object) -> None:
    value = await erlang.async_call("_task_dispose", group)
    if value != "ok":
        result(value)

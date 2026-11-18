import asyncio
import threading
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from inspect import iscoroutinefunction
from types import FunctionType
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
    def __init__(
        self, invoke: Callable[[bytes], Awaitable[bytes]], *, dedicated_loop: bool = False
    ) -> None:
        self._invoke = invoke
        self.dedicated_loop = dedicated_loop
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


type EntryResult = (
    tuple[Literal["ok"], bytes]
    | tuple[Literal["cancelled"]]
    | tuple[Literal["remote_error"], str, str]
)


@dataclass(slots=True)
class _EntryState:
    body: Body | None = None
    sealed: bool = False


_entries: dict[int, _EntryState] = {}


def prepare_entry(token: int) -> None:
    if token in _entries:
        raise RuntimeError("Task entry already prepared")
    _entries[token] = _EntryState()


async def cancel_entry(token: int) -> None:
    """Request cancellation on the owning loop; CPU/native work can delay it."""
    state = _entries[token]
    if state.body is None:
        state.sealed = True
    else:
        state.body.cancel()


async def seal_entry(token: int) -> bool:
    state = _entries[token]
    if state.body is None:
        state.sealed = True
        return True
    return state.body.seal()


def _remote_error(error: BaseException) -> tuple[Literal["remote_error"], str, str]:
    try:
        message = str(error)
    except BaseException:
        message = "Unprintable task exception"
    type_name = type(error).__name__.encode("utf-8", errors="backslashreplace").decode("utf-8")
    message = message.encode("utf-8", errors="backslashreplace").decode("utf-8")
    return "remote_error", type_name, message


async def execute_entry(module: str, name: str, token: int, payload: bytes) -> EntryResult:
    try:
        entry = erlang._task_resolve_entry(module, name)
        if not isinstance(entry, FunctionType) or not iscoroutinefunction(entry):
            raise TypeError("Named tasks require an async Python function")
    except BaseException as error:
        return _remote_error(error)
    state = _entries[token]
    if state.sealed:
        return ("cancelled",)
    if state.body is None:
        state.body = Body(entry)
    try:
        value = await state.body.run(payload)
        if not isinstance(value, bytes):
            raise TypeError("Task entries must return bytes")
        return "ok", value
    except asyncio.CancelledError:
        return ("cancelled",)
    except BaseException as error:
        return _remote_error(error)


class RemoteTaskError(RuntimeError):
    def __init__(self, type_name: str, message: str) -> None:
        self.type_name = type_name
        self.message = message
        super().__init__(type_name, message)


class TaskCrashed(RuntimeError):
    """The child exited: execution stopped, but external effects are unknown."""

    def __init__(self, reason: object) -> None:
        self.reason = reason
        super().__init__(reason)


async def execute(body: Body, ticket: object, payload: bytes) -> bytes:
    try:
        return await body.run(payload)
    finally:
        erlang._actor_complete(ticket)


def dedicated(reference: object) -> bool:
    body = erlang._actor_unwrap(reference)
    if not isinstance(body, Body):
        raise TypeError("Invalid task body")
    return body.dedicated_loop


async def execute_owned(reference: object, ticket: object, payload: bytes) -> tuple[str, object]:
    body = erlang._actor_unwrap(reference)
    # A traceback must not retain the local-object capsule and its context/env.
    reference = None
    if not isinstance(body, Body):
        raise TypeError("Invalid task body")
    try:
        return "ok", await execute(body, ticket, payload)
    except BaseException as error:
        return "python_error", erlang._actor_retain(error)


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


async def start(
    group: object,
    gate: object,
    factory: Callable[[], Body] | Callable[[bytes], Awaitable[bytes]],
    payload: bytes,
    *,
    mode: Literal["worker", "owngil", "isolated"] = "worker",
) -> object:
    """Start a worker factory or a named async byte function in owngil/isolated mode.

    Named tasks resolve the function in their interpreter. Cancellation is cooperative;
    CPU/native-blocked bodies delay it. Remote errors transfer type/message text only.
    Isolated tasks never restart. A child exit without a terminal reply is TaskCrashed,
    even after a cancel request; only a cancelled reply acknowledges cancellation.
    Isolated entry modules must not import erlang.tasks or submit nested tasks.
    """
    if mode != "worker":
        if not isinstance(factory, FunctionType) or not iscoroutinefunction(factory):
            raise TypeError(mode + " tasks require an async Python function")
        if (
            not isinstance(factory.__module__, str)
            or not factory.__qualname__.isidentifier()
            or not all(part.isidentifier() for part in factory.__module__.split("."))
        ):
            raise TypeError(mode + " tasks require importable top-level functions")
        ticket = erlang._actor_reserve(gate, len(payload))
        try:
            return result(
                await erlang.async_call(
                    "_task_start",
                    group,
                    gate,
                    ticket,
                    payload,
                    mode,
                    (factory.__module__, factory.__qualname__),
                )
            )
        finally:
            erlang._actor_abort(ticket)
    if iscoroutinefunction(factory):
        raise TypeError(
            'worker tasks require a factory returning Body; async functions require mode="owngil"'
        )
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
    if isinstance(reply, tuple):
        if len(reply) == 2 and reply[0] == "task_crashed":
            return False, TaskCrashed(reply[1])
        if reply == ("cancelled",):
            return False, asyncio.CancelledError()
        if len(reply) == 3 and reply[0] == "remote_error":
            _, type_name, message = reply
            if not isinstance(type_name, str) or not isinstance(message, str):
                raise TypeError("Invalid remote task exception")
            return False, RemoteTaskError(type_name, message)
    # TaskRef owns one watcher and caches its Python outcome for all observers.
    # Transfer before raising: a traceback may retain every reply-watcher frame.
    if isinstance(reply, tuple) and len(reply) == 2 and reply[0] == "python_error":
        error = erlang._actor_take_exception(reply[1])
        if not isinstance(error, BaseException):
            raise TypeError("Invalid task exception")
        return False, error
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


async def thread_snapshot(group: object, pid: object) -> tuple[int, int, bytes]:
    value = result(await erlang.async_call("_task_snapshot", group, pid))
    match value:
        case (int(os_pid), int(cpu_ns), bytes(stacks)) if os_pid > 0 and cpu_ns >= 0:
            return os_pid, cpu_ns, stacks
        case _:
            raise RuntimeError("Invalid isolated task snapshot", value)


async def terminate(group: object, pid: object) -> None:
    """Request killing the isolated child; outcome() acknowledges its exit."""
    value = await erlang.async_call("_task_terminate", group, pid)
    if value != "ok":
        result(value)


async def dispose(group: object) -> None:
    value = await erlang.async_call("_task_dispose", group)
    if value != "ok":
        result(value)

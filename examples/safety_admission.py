import asyncio
from collections.abc import Callable
from dataclasses import dataclass, field


@dataclass(slots=True)
class _WorkState:
    started: asyncio.Event = field(default_factory=asyncio.Event)
    cancelled: asyncio.Event = field(default_factory=asyncio.Event)
    finish: asyncio.Event = field(default_factory=asyncio.Event)
    request_cancel: Callable[[], bool] | None = None
    rejected_calls: int = 0


_state = _WorkState()


async def work() -> str:
    task = asyncio.current_task()
    if task is None:
        raise RuntimeError("work requires a Task")
    _state.request_cancel = task.cancel
    _state.started.set()
    try:
        await _state.finish.wait()
    except asyncio.CancelledError:
        _state.cancelled.set()
        await _state.finish.wait()
    return "finished"


async def ready() -> None:
    await _state.started.wait()


async def cancel_and_acknowledge() -> None:
    if _state.request_cancel is None:
        raise RuntimeError("work has not started")
    _state.request_cancel()
    await _state.cancelled.wait()


def allow_completion() -> None:
    _state.finish.set()


def rejected() -> int:
    _state.rejected_calls += 1
    return _state.rejected_calls


def rejected_count() -> int:
    return _state.rejected_calls

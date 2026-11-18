import asyncio
from dataclasses import dataclass
from threading import get_native_id, local

from greenlet import getcurrent, greenlet


class ThreadState(local):
    def __init__(self) -> None:
        self.retained = False


@dataclass
class SwitchState:
    pending: greenlet | None = None
    owner: int | None = None


thread_state = ThreadState()
state = SwitchState()


def yield_value(value: str) -> str:
    parent = getcurrent().parent
    if parent is None:
        raise RuntimeError("Expected a child greenlet")
    result = parent.switch(value)
    if not isinstance(result, str):
        raise TypeError("Expected a string")
    return result


def begin_switch(value: str) -> str:
    state.owner = get_native_id()
    thread_state.retained = True
    state.pending = greenlet(lambda: yield_value(value))
    result = state.pending.switch()
    if not isinstance(result, str):
        raise TypeError("Expected a string")
    return result


def finish_switch() -> str:
    if state.owner != get_native_id() or state.pending is None:
        raise RuntimeError("Expected the original scheduler thread")
    result = state.pending.switch("resumed")
    if not isinstance(result, str):
        raise TypeError("Expected a string")
    return result


def fail() -> None:
    raise ValueError("greenlet failure")


def fail_switch() -> None:
    greenlet(fail).switch()


def thread_state_preserved() -> bool:
    return state.owner == get_native_id() and thread_state.retained


async def pooled_switch(value: str) -> str:
    loop = asyncio.get_running_loop()
    if not loop.is_running():
        raise RuntimeError("Expected a persistent loop driver")
    owner = get_native_id()
    pending = greenlet(lambda: yield_value(value))
    result = pending.switch()
    if result != value:
        raise RuntimeError("Unexpected initial value")
    await asyncio.to_thread(get_native_id)
    if get_native_id() != owner:
        raise RuntimeError("Loop changed native threads")
    result = pending.switch(value)
    if not isinstance(result, str):
        raise TypeError("Expected a string")
    return result


async def pooled_failure() -> None:
    await asyncio.to_thread(get_native_id)
    greenlet(fail).switch()

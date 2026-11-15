import asyncio
import os
import time
from collections.abc import Callable
from pathlib import Path
from typing import Never
from unittest.mock import patch

_entered: set[str] = set()
_cancelled: set[str] = set()
_release: dict[str, asyncio.Event] = {}
_cleanup: dict[str, asyncio.Event] = {}
_cancel: dict[str, Callable[[], bool]] = {}
_constructor_fault = patch("_asyncio.Task", side_effect=MemoryError("injected constructor failure"))


async def hold(name: str) -> str:
    task = asyncio.current_task()
    if task is None:
        raise RuntimeError("hold requires a Task")
    _cancel[name] = task.cancel
    _release[name] = asyncio.Event()
    _cleanup[name] = asyncio.Event()
    _entered.add(name)
    try:
        await _release[name].wait()
    except asyncio.CancelledError:
        _cancelled.add(name)
        await _cleanup[name].wait()
    return name


def entered(name: str) -> bool:
    return name in _entered


def cancelled(name: str) -> bool:
    return name in _cancelled


def release(name: str) -> None:
    _release[name].set()
    _cleanup[name].set()


def cancel(name: str) -> bool:
    return _cancel[name]()


def cancel_before_start() -> None:
    for task in asyncio.all_tasks():
        task.cancel()


def _deny_factory(loop: asyncio.AbstractEventLoop, coro: object, **kwargs: object) -> Never:
    raise RuntimeError("this factory must not be invoked for admitted work")


def install_factory() -> None:
    asyncio.get_running_loop().set_task_factory(_deny_factory)


def reset_factory() -> None:
    asyncio.get_running_loop().set_task_factory(None)


def fail_constructor() -> None:
    _constructor_fault.start()


def restore_constructor() -> None:
    _constructor_fault.stop()


def fail_sync() -> None:
    raise RuntimeError("admission synchronous failure")


async def fail_async() -> None:
    await asyncio.sleep(0)
    raise RuntimeError("admission asynchronous failure")


def block(started: str | bytes, stopped: str | bytes) -> str:
    Path(os.fsdecode(started)).write_text("started")
    end = Path(os.fsdecode(stopped))
    deadline = time.monotonic() + 10
    while not end.exists():
        if time.monotonic() > deadline:
            raise TimeoutError("test did not acknowledge stop")
        time.sleep(0.005)
    return "stopped"

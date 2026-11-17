import asyncio
import io
import threading
from collections.abc import Coroutine
from contextlib import ExitStack, redirect_stderr
from dataclasses import dataclass, field
from unittest.mock import patch

import erlang


@dataclass
class Teardown:
    closing: threading.Event = field(default_factory=threading.Event)
    release: threading.Event = field(default_factory=threading.Event)
    closed: threading.Event = field(default_factory=threading.Event)
    scope: ExitStack = field(default_factory=ExitStack)
    stderr: io.StringIO = field(default_factory=io.StringIO)


teardown = Teardown()


async def arm() -> str:
    teardown.closing.clear()
    teardown.release.clear()
    teardown.closed.clear()
    teardown.stderr.seek(0)
    teardown.stderr.truncate()
    loop = asyncio.get_running_loop()
    close = loop.close

    def closing() -> None:
        teardown.closing.set()
        if not teardown.release.wait(5):
            raise TimeoutError("Task processing did not reach the teardown barrier")
        try:
            close()
        finally:
            teardown.closed.set()

    teardown.scope.enter_context(redirect_stderr(teardown.stderr))
    teardown.scope.enter_context(patch.object(loop, "close", closing))
    return "armed"


async def completed() -> str:
    return "completed"


def wait_closing() -> str:
    if not teardown.closing.wait(5):
        raise TimeoutError("Loop owner did not begin teardown")
    return "closing"


def retire() -> None:
    teardown.release.set()
    if not teardown.closed.wait(5):
        raise TimeoutError("Loop owner did not finish teardown")


def retiring_factory() -> Coroutine[object, object, str]:
    retire()
    return completed()


def retiring_result() -> str:
    retire()
    return "completed"


async def retiring_completed() -> str:
    erlang.call("owner_destroy_loop")
    return "completed"


def retiring_empty() -> bytes:
    retire()
    return b""


def retiring_error() -> None:
    retire()
    raise ValueError("completed failure")


def finish() -> str:
    teardown.release.set()
    teardown.scope.close()
    assert "SystemError" not in teardown.stderr.getvalue(), teardown.stderr.getvalue()
    return "no-system-error"

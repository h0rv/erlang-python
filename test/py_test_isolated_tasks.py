import asyncio

from erlang.tasks import (
    Body,
    RemoteTaskError,
    TaskCrashed,
    dispose,
    open_group,
    outcome,
    shutdown,
    start,
)
from py_test_isolated_task_entries import crash, echo, failure


async def api() -> bool:
    group, gate = await open_group(1, 100)
    try:

        async def nested(payload: bytes) -> bytes:
            return payload

        def synchronous() -> Body:
            return Body(echo)

        for invalid in (nested, synchronous, lambda payload: asyncio.sleep(0, result=payload)):
            try:
                await start(group, gate, invalid, b"", mode="isolated")
            except TypeError as error:
                assert "isolated tasks require" in str(error)
            else:
                raise AssertionError("Invalid isolated entry accepted")

        for payload in (b"", b"work", b"\x00\xff"):
            pid = await start(group, gate, echo, payload, mode="isolated")
            assert await outcome(group, pid) == (True, payload)

        pid = await start(group, gate, failure, b"", mode="isolated")
        success, error = await outcome(group, pid)
        assert not success and isinstance(error, RemoteTaskError), error
        assert (error.type_name, error.message) == ("ValueError", "isolated failure\\udcff"), error

        original = echo.__module__, echo.__qualname__
        for module, name, type_name in (
            ("py_test_task_import_failure", "echo", "ImportError"),
            (original[0], "missing", "AttributeError"),
            (original[0], "os", "TypeError"),
            (original[0], "invalid_result", "TypeError"),
        ):
            echo.__module__, echo.__qualname__ = module, name
            try:
                pid = await start(group, gate, echo, b"", mode="isolated")
            finally:
                echo.__module__, echo.__qualname__ = original
            success, error = await outcome(group, pid)
            assert not success and isinstance(error, RemoteTaskError), error
            assert error.type_name == type_name, error
            if type_name == "ImportError":
                assert error.message == "entry module import failed", error
            if name == "invalid_result":
                assert error.message == "Task entries must return bytes", error

        pid = await start(group, gate, crash, b"", mode="isolated")
        success, error = await outcome(group, pid)
        assert not success and isinstance(error, TaskCrashed), error
        assert error.reason == ("signal", 6), error
        pid = await start(group, gate, echo, b"after crash", mode="isolated")
        assert await outcome(group, pid) == (True, b"after crash")
        await shutdown(group, 5000)
    finally:
        await dispose(group)
    return True

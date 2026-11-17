import asyncio
import time

import erlang
from _erlang_impl._tasks import _entries
from erlang.tasks import (
    RemoteTaskError,
    cancel,
    dispose,
    entrypoint,
    open_group,
    outcome,
    shutdown,
    start,
)
from py_test_entrée import résumé


@entrypoint
async def echo(payload: bytes) -> bytes:
    await asyncio.sleep(0)
    return payload


@entrypoint
async def failure(payload: bytes) -> bytes:
    raise ValueError("remote failure")


@entrypoint
async def surrogate_failure(payload: bytes) -> bytes:
    raise ValueError("remote\udcff failure")


async def surrogate_error() -> bool:
    group, gate = await open_group(1, 100)
    pid = await start(group, gate, surrogate_failure, b"", mode="owngil")
    success, error = await outcome(group, pid)
    assert not success and isinstance(error, RemoteTaskError)
    assert error.type_name == "ValueError"
    assert error.message == "remote\\udcff failure"
    pid = await start(group, gate, echo, b"completed", mode="owngil")
    assert await outcome(group, pid) == (True, b"completed")
    await shutdown(group, 1000)
    await dispose(group)
    return True


async def unicode_identifiers() -> bool:
    group, gate = await open_group(1, 100)
    for module, name in (
        ("", "echo"),
        ("py_test_task_entries.", "echo"),
        ("py_test_task_entries", "echo\n"),
        ("py_test_task_entries", "1résumé"),
        ("py_test_task_entries", "résumé.unknown"),
        ("py_test_task_entries", "\u037a"),
        ("py_test_task_entries", "\u2e2f"),
        ("py_test_task_entries", "\N{SNOWMAN}"),
    ):
        ticket = erlang._actor_reserve(gate, 0)
        try:
            reply = await erlang.async_call(
                "_task_start", group, gate, ticket, b"", "owngil", (module, name)
            )
            assert reply == ("error", "invalid_task_entry")
        finally:
            erlang._actor_abort(ticket)
    pid = await start(group, gate, résumé, b"unicode", mode="owngil")
    assert await outcome(group, pid) == (True, b"unicode")
    await shutdown(group, 1000)
    await dispose(group)
    return True


@entrypoint
async def asleep(payload: bytes) -> bytes:
    await asyncio.sleep(60)
    return payload


@entrypoint
async def waiting(payload: bytes) -> bytes:
    await erlang.async_call("task_entry_entered", payload)
    await asyncio.sleep(60)
    return payload


@entrypoint
async def must_not_run(payload: bytes) -> bytes:
    raise AssertionError("A sealed entry executed")


@entrypoint
async def cpu(payload: bytes) -> bytes:
    deadline = int(payload)
    await asyncio.sleep(max(0, (deadline - time.monotonic_ns()) / 1_000_000_000))
    begin = time.monotonic_ns()
    value = 1
    while time.monotonic_ns() - begin < 250_000_000:
        value = (value * 13 + 17) % 100_003
    end = time.monotonic_ns()
    assert value >= 0
    return (str(begin) + ":" + str(end)).encode()


def malformed(token: int, payload: bytes) -> bytes:
    raise AssertionError("A non-entry callable executed")


async def unresolved(payload: bytes) -> bytes:
    raise AssertionError("An unresolved task body executed")


async def resolution_failure(module: str, name: str, type_name: str, message: str) -> bool:
    group, gate = await open_group(1, 100)
    entry = entrypoint(unresolved)
    entry.module, entry.name = module, name
    pid = await start(group, gate, entry, b"", mode="owngil")
    success, error = await outcome(group, pid)
    assert not success and isinstance(error, RemoteTaskError)
    assert error.type_name == type_name, error
    assert error.message == message, error
    pid = await start(group, gate, echo, b"completed", mode="owngil")
    assert await outcome(group, pid) == (True, b"completed")
    await shutdown(group, 1000)
    await dispose(group)
    return True


async def sealed(token: int) -> bool:
    return _entries[token].sealed


async def api() -> bool:
    group, gate = await open_group(1, 100)
    ticket = erlang._actor_reserve(gate, 0)
    try:
        reply = await erlang.async_call(
            "_task_start", group, gate, ticket, b"", "isolated", (echo.module, echo.name)
        )
        assert reply == ("error", ("unsupported_task_mode", "isolated"))
    finally:
        erlang._actor_abort(ticket)
    for payload in (b"", b"work", b"\x00\xff"):
        pid = await start(group, gate, echo, payload, mode="owngil")
        assert await outcome(group, pid) == (True, payload)
    pid = await start(group, gate, failure, b"", mode="owngil")
    success, error = await outcome(group, pid)
    assert not success and isinstance(error, RemoteTaskError)
    assert error.type_name == "ValueError" and error.message == "remote failure"
    assert error.__traceback__ is None
    pid = await start(group, gate, asleep, b"", mode="owngil")
    await cancel(group, pid)
    success, error = await outcome(group, pid)
    assert not success and isinstance(error, asyncio.CancelledError)

    @entrypoint
    async def nested(payload: bytes) -> bytes:
        return payload

    anonymous = entrypoint(lambda payload: asyncio.sleep(0, result=payload))
    for invalid in (nested, anonymous):
        try:
            await start(group, gate, invalid, b"", mode="owngil")
        except TypeError:
            pass
        else:
            raise AssertionError("Non-importable entry was accepted")
    await shutdown(group, 1000)
    await dispose(group)
    return True

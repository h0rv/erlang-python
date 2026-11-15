import asyncio
import sys
import threading
from collections.abc import Callable
from dataclasses import dataclass
from unittest.mock import patch

import erlang
import py_event_loop as native
from _erlang_impl._loop import ErlangEventLoop as NativeLoop
from erlang.channel import Channel


@dataclass
class Inspection:
    owner: NativeLoop | None = None
    channel: Channel | None = None
    waiter: asyncio.Task[bytes] | None = None
    barrier: threading.Barrier | None = None
    winner: NativeLoop | None = None


inspection = Inspection()


def rejects(operation: Callable[[], object]) -> None:
    try:
        operation()
    except RuntimeError:
        return
    raise AssertionError("A second native callback owner was accepted")


async def setup() -> str:
    owner = asyncio.get_running_loop()
    assert isinstance(owner, NativeLoop)
    inspection.owner = owner
    inspection.channel = Channel.create_bytes(capacity=2, max_bytes=64)
    inspection.waiter = asyncio.create_task(inspection.channel.receive_bytes())
    ready = asyncio.Future[None](loop=owner)
    owner.call_soon(ready.set_result, None)
    await ready
    assert inspection.channel.snapshot()[5] == 1
    return "waiting"


def reject_active(capsule: object, shared: bool) -> str:
    owner = inspection.owner
    assert owner is not None and owner.is_running()
    assert native._has_loop_ref(capsule)
    references = sys.getrefcount(owner)
    native._set_loop_ref(capsule, owner)
    rejects(lambda: NativeLoop(capsule))
    rejects(lambda: native._set_loop_ref(capsule, object()))
    rejects(lambda: native._clear_loop_ref(capsule, object()))
    rejects(lambda: native._clear_loop_ref(capsule, owner))
    if shared:
        rejects(NativeLoop)
        rejects(lambda: native._set_global_loop_ref(object()))
        native._set_global_loop_ref(owner)
    partial = NativeLoop.__new__(NativeLoop)
    rejects(lambda: partial.__init__(capsule))
    rejects(partial.close)
    assert native._has_loop_ref(capsule)
    assert owner.is_running()
    assert inspection.channel is not None and inspection.channel.snapshot()[5] == 1
    assert sys.getrefcount(owner) == references
    return "exclusive-owner-preserved"


async def finish() -> str:
    assert inspection.channel is not None and inspection.waiter is not None
    inspection.channel.send_bytes_nowait(b"original-callback-owner")
    assert await inspection.waiter == b"original-callback-owner"
    assert await erlang.async_call("owner_echo", "original-reply") == "original-reply"
    inspection.channel.abort()
    return "callbacks-complete"


def initial_and_closed(capsule: object) -> str:
    assert not native._has_loop_ref(capsule)
    first = NativeLoop(capsule)
    assert native._has_loop_ref(capsule) and not first.is_running()
    rejects(lambda: NativeLoop(capsule))
    rejects(lambda: native._set_loop_ref(capsule, object()))
    first.close()
    assert not native._has_loop_ref(capsule)
    second = NativeLoop(capsule)
    first.close()
    rejects(lambda: native._clear_loop_ref(capsule, first))
    rejects(lambda: native._clear_loop_ref(capsule, first, True))
    rejects(lambda: native._set_loop_ref(capsule, first))
    assert native._has_loop_ref(capsule)
    second.close()
    assert not native._has_loop_ref(capsule)
    return "exact-release-and-rebind"


def initialization_error(capsule: object) -> str:
    assert not native._has_loop_ref(capsule)
    with patch("_erlang_impl._loop.WeakSet", side_effect=MemoryError("before native claim")):
        try:
            NativeLoop(capsule)
        except MemoryError:
            pass
        else:
            raise AssertionError("Initialization fault did not run")
    assert not native._has_loop_ref(capsule)
    owner = NativeLoop(capsule)
    assert native._has_loop_ref(capsule)
    owner.close()
    return "initialization-error-unclaimed"


def disposal(capsule: object) -> str:
    owner = NativeLoop(capsule)
    assert native._clear_loop_ref(capsule, owner, True)
    rejects(lambda: NativeLoop(capsule))
    owner.close()
    assert not native._has_loop_ref(capsule)
    return "disposed-resource-cannot-rebind"


def prepare_concurrent() -> str:
    inspection.barrier = threading.Barrier(2, timeout=5)
    inspection.winner = None
    return "prepared"


def contend(capsule: object) -> str:
    assert inspection.barrier is not None
    inspection.barrier.wait()
    try:
        inspection.winner = NativeLoop(capsule)
    except RuntimeError:
        return "rejected"
    return "claimed"


def finish_concurrent(capsule: object) -> str:
    assert inspection.winner is not None
    assert native._has_loop_ref(capsule)
    inspection.winner.close()
    inspection.winner = None
    assert not native._has_loop_ref(capsule)
    return "one-claim-released"

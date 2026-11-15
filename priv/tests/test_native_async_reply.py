import asyncio
import sys
from dataclasses import dataclass
from types import ModuleType
from unittest.mock import patch

import pytest

with patch.dict(sys.modules, {"erlang": ModuleType("erlang")}):
    from _erlang_impl._loop import EVENT_TYPE_TIMER, ErlangEventLoop


@dataclass
class Reply:
    owner: ErlangEventLoop
    registration: int
    abandoned: bool = False
    taken: bool = False


class NativeReplies(ModuleType):
    def __init__(self) -> None:
        super().__init__("erlang")
        self.replies: list[Reply] = []
        self.complete_immediately = True
        self.fail_send = False

    def _prepare_native_async_reply(
        self, capsule: object, owner: ErlangEventLoop
    ) -> tuple[int, Reply]:
        registration = (1 << 63) + len(self.replies)
        reply = Reply(owner, registration)
        self.replies.append(reply)
        return registration, reply

    def _send_async_request(
        self, name: str, args: tuple[object, ...], reply: Reply
    ) -> int:
        assert reply.registration in reply.owner._timers
        if self.fail_send:
            raise ValueError("submission rejected")
        if self.complete_immediately:
            reply.owner._dispatch(reply.registration, EVENT_TYPE_TIMER)
        return reply.registration

    def _take_native_async_reply(self, reply: Reply, owner: ErlangEventLoop) -> int:
        assert owner is reply.owner
        assert asyncio.get_running_loop() is owner
        assert not reply.abandoned
        assert not reply.taken
        reply.taken = True
        return 42

    def _abandon_native_async_reply(self, reply: Reply) -> None:
        reply.abandoned = True


@pytest.fixture
def native(monkeypatch: pytest.MonkeyPatch) -> NativeReplies:
    native = NativeReplies()
    monkeypatch.setitem(sys.modules, "erlang", native)
    return native


def test_reply_is_registered_before_submission_and_taken_on_owner(
    native: NativeReplies,
) -> None:
    first = ErlangEventLoop()
    second = ErlangEventLoop()
    try:
        assert first.run_until_complete(first._async_call("echo", (42,))) == 42
        assert second.run_until_complete(second._async_call("echo", (42,))) == 42
        assert native.replies[0].registration != native.replies[1].registration
        assert all(reply.taken and reply.abandoned for reply in native.replies)
        assert not first._timers and not second._timers
        assert not first._readers and not second._readers
    finally:
        first.close()
        second.close()


def test_cancelled_reply_cannot_continue_on_replacement_owner(
    native: NativeReplies,
) -> None:
    native.complete_immediately = False
    loop = ErlangEventLoop()
    task = loop.create_task(loop._async_call("held", ()))
    loop.call_soon(task.cancel)
    try:
        with pytest.raises(asyncio.CancelledError):
            loop.run_until_complete(task)
        [reply] = native.replies
        assert reply.abandoned and not reply.taken
        assert not loop._timers
        # A late notification has no handler. It does not decode or replay.
        loop._dispatch(reply.registration, EVENT_TYPE_TIMER)
        assert not loop._ready
    finally:
        loop.close()
    replacement = ErlangEventLoop()
    try:
        replacement._dispatch(reply.registration, EVENT_TYPE_TIMER)
        assert not replacement._ready
        assert not reply.taken
    finally:
        replacement.close()


def test_send_failure_releases_reserved_reply(native: NativeReplies) -> None:
    native.fail_send = True
    loop = ErlangEventLoop()
    try:
        with pytest.raises(ValueError, match="submission rejected"):
            loop.run_until_complete(loop._async_call("rejected", ()))
        assert not loop._timers
        assert native.replies[0].abandoned
    finally:
        loop.close()

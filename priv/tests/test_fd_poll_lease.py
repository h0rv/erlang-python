import os
import socket
import sys
from enum import StrEnum
from types import ModuleType
from unittest.mock import patch

import pytest

with patch.dict(sys.modules, {"erlang": ModuleType("erlang")}):
    from _erlang_impl._fd import FdRetirementError, parse_fd_retirement
    from _erlang_impl._loop import (
        EVENT_TYPE_READ,
        ErlangEventLoop,
        _MockLoopCapsule,
        _MockNifModule,
    )


class Failure(StrEnum):
    NONE = "none"
    ALLOCATION = "allocation"
    STOP = "stop"
    UNSUBMITTED = "unsubmitted"
    CANCEL = "cancel"


class LeaseBoundary(_MockNifModule):
    def __init__(self) -> None:
        super().__init__()
        self.failure = Failure.NONE
        self.leases: dict[int, int] = {}
        self.pending: list[int] = []

    def _add_reader_for(
        self, capsule: _MockLoopCapsule, fd: int, callback_id: int
    ) -> int:
        key = super()._add_reader_for(capsule, fd, callback_id)
        self.leases[key] = os.dup(fd)
        return key

    def _add_writer_for(
        self, capsule: _MockLoopCapsule, fd: int, callback_id: int
    ) -> int:
        key = super()._add_writer_for(capsule, fd, callback_id)
        self.leases[key] = os.dup(fd)
        return key

    def _clear_fd_read(self, fd_key: int) -> None:
        if self.failure == Failure.CANCEL:
            raise RuntimeError("simulated CANCEL failure at Python boundary")

    def _release_fd_resource(self, fd_key: int, take_ownership: bool = False) -> str:
        if self.failure == Failure.ALLOCATION:
            raise MemoryError("simulated environment allocation failure")
        if self.failure in (Failure.STOP, Failure.UNSUBMITTED):
            raise RuntimeError("simulated STOP failure or unsubmitted STOP")
        poll_fd = self.leases.pop(fd_key, None)
        if poll_fd is None:
            return "absent"
        self.pending.append(poll_fd)
        self._fd_by_key.pop(fd_key)
        return "poll_pending"

    def finish(self) -> None:
        for poll_fd in self.pending:
            os.close(poll_fd)
        self.pending.clear()
        assert not self.leases


@pytest.mark.parametrize(
    "failure", [Failure.ALLOCATION, Failure.STOP, Failure.UNSUBMITTED]
)
def test_close_failure_retains_socket_mapping_callback_and_retry_key(
    failure: Failure,
) -> None:
    loop = ErlangEventLoop()
    native = LeaseBoundary()
    loop._pel = native
    left, right = socket.socketpair()
    try:
        fd = left.fileno()
        loop.add_reader(fd, lambda: None)
        key = loop._fd_resources[fd]
        callback = loop._readers[fd][2]
        native.failure = failure
        with pytest.raises(FdRetirementError) as caught:
            loop._close_socket(left)
        assert caught.value.key == key
        assert left.fileno() == fd
        os.fstat(fd)
        os.fstat(native.leases[key])
        assert loop._fd_resources[fd] == key
        assert callback in loop._callbacks_by_cid
        assert loop._closing_sockets[key] is left
        native.failure = Failure.NONE
        loop._close_socket(left)
        assert left.fileno() == -1
        assert fd not in loop._fd_resources
        assert not loop._closing_sockets
        assert len(native.pending) == 1
        os.fstat(native.pending[0])
    finally:
        native.failure = Failure.NONE
        loop.close()
        native.finish()
        left.close()
        right.close()


@pytest.mark.parametrize(
    "failure", [Failure.ALLOCATION, Failure.STOP, Failure.UNSUBMITTED]
)
def test_remove_failure_does_not_discard_retry_handle(failure: Failure) -> None:
    loop = ErlangEventLoop()
    native = LeaseBoundary()
    loop._pel = native
    left, right = socket.socketpair()
    try:
        fd = left.fileno()
        loop.add_reader(fd, lambda: None)
        key = loop._fd_resources[fd]
        native.failure = failure
        with pytest.raises(FdRetirementError):
            loop.remove_reader(fd)
        assert loop._fd_resources[fd] == key and fd in loop._readers
        assert key in native.leases
        native.failure = Failure.NONE
        assert loop.remove_reader(fd)
        left.close()
        os.fstat(native.pending[0])
    finally:
        native.failure = Failure.NONE
        loop.close()
        native.finish()
        left.close()
        right.close()


def test_cancel_failure_preserves_registration_and_retry_retires_the_lease() -> None:
    loop = ErlangEventLoop()
    native = LeaseBoundary()
    loop._pel = native
    left, right = socket.socketpair()
    try:
        fd = left.fileno()
        loop.add_reader(fd, lambda: None)
        loop.add_writer(fd, lambda: None)
        native.failure = Failure.CANCEL
        with pytest.raises(FdRetirementError):
            loop.remove_reader(fd)
        assert fd in loop._readers and fd in loop._writers
        native.failure = Failure.NONE
        assert loop.remove_reader(fd)
        assert fd not in loop._readers and fd not in loop._writers
    finally:
        native.failure = Failure.NONE
        loop.close()
        native.finish()
        left.close()
        right.close()


def test_pending_stop_isolated_from_external_close_and_immediate_re_registration() -> (
    None
):
    loop = ErlangEventLoop()
    native = LeaseBoundary()
    loop._pel = native
    left, right = socket.socketpair()
    callbacks: list[str] = []
    try:
        fd = left.fileno()
        loop.add_reader(fd, callbacks.append, "old")
        old_id = loop._readers[fd][2]
        loop._dispatch(old_id, EVENT_TYPE_READ)
        assert loop.remove_reader(fd)
        old_poll = native.pending[0]
        assert old_poll != fd
        left.close()
        replacement, peer = socket.socketpair()
        try:
            assert replacement.fileno() == fd
            loop.add_reader(fd, callbacks.append, "new")
            new_id = loop._readers[fd][2]
            assert new_id != old_id
            assert native.leases[loop._fd_resources[fd]] != old_poll
            loop._dispatch(old_id, EVENT_TYPE_READ)
            while loop._ready:
                loop._ready.popleft()._run()
            assert callbacks == []
            loop._dispatch(new_id, EVENT_TYPE_READ)
            loop._ready.popleft()._run()
            assert callbacks == ["new"]
            assert loop.remove_reader(fd)
            loop.add_writer(fd, callbacks.append, "writer")
            assert loop.remove_writer(fd)
        finally:
            replacement.close()
            peer.close()
        os.fstat(old_poll)
    finally:
        loop.close()
        native.finish()
        left.close()
        right.close()


def test_close_failure_keeps_loop_owner_retryable() -> None:
    loop = ErlangEventLoop()
    native = LeaseBoundary()
    loop._pel = native
    left, right = socket.socketpair()
    try:
        loop.add_reader(left.fileno(), lambda: None)
        native.failure = Failure.STOP
        with pytest.raises(FdRetirementError):
            loop.close()
        assert not loop.is_closed() and loop._fd_resources
        native.failure = Failure.NONE
        loop.close()
        assert loop.is_closed() and not loop._fd_resources
    finally:
        native.failure = Failure.NONE
        loop.close()
        native.finish()
        left.close()
        right.close()


def test_retirement_boundary_rejects_the_old_ambiguous_none_result() -> None:
    with pytest.raises(ValueError):
        parse_fd_retirement(None)

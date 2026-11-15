import asyncio
import os
import socket
import sys
from enum import StrEnum
from types import ModuleType
from typing import override
from unittest.mock import patch

import pytest

with patch.dict(sys.modules, {"erlang": ModuleType("erlang")}):
    from _erlang_impl._fd import (
        FdCallback,
        FdPublication,
        FdPublicationPhase,
        FdRetirementError,
        FdWatcher,
        parse_fd_retirement,
    )
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

    @override
    def _add_reader_for(
        self, capsule: _MockLoopCapsule, fd: int, callback_id: int
    ) -> int:
        key = super()._add_reader_for(capsule, fd, callback_id)
        self.leases[key] = os.dup(fd)
        return key

    @override
    def _add_writer_for(
        self, capsule: _MockLoopCapsule, fd: int, callback_id: int
    ) -> int:
        key = super()._add_writer_for(capsule, fd, callback_id)
        self.leases[key] = os.dup(fd)
        return key

    @override
    def _clear_fd_read(self, fd_key: int) -> None:
        if self.failure == Failure.CANCEL:
            raise RuntimeError("simulated CANCEL failure at Python boundary")

    @override
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


def test_recv_does_not_publish_success_when_retirement_fails() -> None:
    loop = ErlangEventLoop()
    native = LeaseBoundary()
    loop._pel = native
    left, right = socket.socketpair()
    left.setblocking(False)
    right.setblocking(False)
    native.failure = Failure.STOP

    def readable() -> None:
        callback = loop._readers[left.fileno()][2]
        loop._dispatch(callback, EVENT_TYPE_READ)

    async def receive() -> None:
        task = asyncio.create_task(loop.sock_recv(left, 4))
        loop.call_soon(readable)
        await task

    try:
        assert right.send(b"recv") == 4
        with pytest.raises(FdRetirementError):
            loop.run_until_complete(receive())
        fd = left.fileno()
        key = loop._fd_resources[fd]
        assert fd >= 0 and fd in loop._readers
        assert key in native.leases and key in loop._fd_retirement_failed
        os.fstat(fd)
    finally:
        native.failure = Failure.NONE
        loop._close_socket(left)
        loop.close()
        native.finish()
        left.close()
        right.close()


def test_retirement_boundary_rejects_the_old_ambiguous_none_result() -> None:
    with pytest.raises(ValueError):
        parse_fd_retirement(None)


class PublicationFailure[V](dict[int, V]):
    def __init__(
        self,
        source: dict[int, V] | None = None,
        *,
        after_write: bool = False,
        persistent: bool = False,
    ) -> None:
        super().__init__({} if source is None else source)
        self.fail = True
        self.after_write = after_write
        self.persistent = persistent

    @override
    def __setitem__(self, key: int, value: V) -> None:
        if self.fail:
            self.fail = self.persistent
            if self.after_write:
                super().__setitem__(key, value)
            raise MemoryError("simulated Python dictionary publication failure")
        super().__setitem__(key, value)


class NoFallbackSet(set[int]):
    @override
    def add(self, value: int) -> None:
        raise AssertionError("Failure handling must not allocate a fallback owner")


@pytest.mark.parametrize("reading", [True, False])
def test_old_publication_order_loses_reader_and_writer_key(reading: bool) -> None:
    loop = ErlangEventLoop()
    native = LeaseBoundary()
    capsule = _MockLoopCapsule()
    loop._loop_capsule = capsule
    loop._pel = native
    loop._fd_resources = PublicationFailure[int]()
    left, right = socket.socketpair()
    try:
        fd = left.fileno()
        # Exact e133 failure window: native returns before the first map write.
        with pytest.raises(MemoryError):
            if reading:
                key = native._add_reader_for(capsule, fd, 1)
            else:
                key = native._add_writer_for(capsule, fd, 1)
            loop._fd_resources[fd] = key
        assert not loop._fd_resources and not loop._fd_retirement_failed
        assert not loop._fd_publications and len(native.leases) == 1
        # This deliberate negative-control fixture, not loop.close(), knows it.
        for leaked_key in tuple(native.leases):
            native._release_fd_resource(leaked_key)
    finally:
        loop.close()
        native.finish()
        left.close()
        right.close()


class PublicationBoundary(LeaseBoundary):
    def __init__(self, loop: ErlangEventLoop) -> None:
        super().__init__()
        self.loop = loop
        self.before_effect: FdPublication | None = None
        self.update_called = False

    def witness(self, fd: int) -> None:
        publication = self.loop._fd_publications[fd]
        assert publication.key == 0
        assert publication.phase == FdPublicationPhase.PREPARED
        self.before_effect = publication

    @override
    def _add_reader_for(
        self,
        capsule: _MockLoopCapsule,
        fd: int,
        callback_id: int,
    ) -> int:
        self.witness(fd)
        return super()._add_reader_for(capsule, fd, callback_id)

    @override
    def _add_writer_for(
        self,
        capsule: _MockLoopCapsule,
        fd: int,
        callback_id: int,
    ) -> int:
        self.witness(fd)
        return super()._add_writer_for(capsule, fd, callback_id)

    @override
    def _update_fd_read(self, fd_key: int, callback_id: int) -> None:
        self.update_called = True
        if self.failure == Failure.STOP:
            raise RuntimeError("simulated uncertain native callback update")

    @override
    def _update_fd_write(self, fd_key: int, callback_id: int) -> None:
        self.update_called = True
        if self.failure == Failure.STOP:
            raise RuntimeError("simulated uncertain native callback update")


def register(loop: ErlangEventLoop, fd: int, *, reading: bool) -> None:
    if reading:
        loop.add_reader(fd, lambda: None)
    else:
        loop.add_writer(fd, lambda: None)


@pytest.mark.parametrize("reading", [True, False])
@pytest.mark.parametrize("rollback_fails", [True, False])
@pytest.mark.parametrize("after_write", [True, False])
def test_publication_slot_owns_native_key_before_mapping_and_failed_rollback(
    reading: bool,
    rollback_fails: bool,
    after_write: bool,
) -> None:
    loop = ErlangEventLoop()
    native = PublicationBoundary(loop)
    loop._pel = native
    loop._fd_resources = PublicationFailure[int](after_write=after_write)
    loop._fd_retirement_failed = NoFallbackSet()
    left, right = socket.socketpair()
    try:
        fd = left.fileno()
        if rollback_fails:
            native.failure = Failure.STOP
        with pytest.raises(RuntimeError):
            register(loop, fd, reading=reading)
        publication = native.before_effect
        assert publication is not None and publication.key > 0
        if rollback_fails:
            assert loop._fd_publications[fd] is publication
            assert publication.phase == FdPublicationPhase.ROLLBACK_FAILED
            assert publication.key in native.leases
            os.fstat(native.leases[publication.key])
            with pytest.raises(FdRetirementError):
                loop._close_socket(left)
            assert publication.closing_socket is left and left.fileno() == fd
            assert loop._fd_publications[fd] is publication
            native.failure = Failure.NONE
            # close discovers the slot even if _fd_resources is still empty.
            loop.close()
            assert left.fileno() == -1
        else:
            assert not loop._fd_publications and not native.leases
            assert not loop._fd_resources
            assert publication.phase == FdPublicationPhase.RETIRED
        assert not loop._fd_retirement_failed
        assert not loop._callbacks_by_cid
    finally:
        native.failure = Failure.NONE
        loop.close()
        native.finish()
        left.close()
        right.close()


@pytest.mark.parametrize("reading", [True, False])
def test_other_direction_survives_python_publication_failure(reading: bool) -> None:
    loop = ErlangEventLoop()
    native = PublicationBoundary(loop)
    loop._pel = native
    left, right = socket.socketpair()
    try:
        fd = left.fileno()
        register(loop, fd, reading=not reading)
        key = loop._fd_resources[fd]
        others = loop._writers if reading else loop._readers
        original = others[fd]
        if reading:
            loop._readers = PublicationFailure[FdWatcher]()
        else:
            loop._writers = PublicationFailure[FdWatcher]()
        with pytest.raises(RuntimeError):
            register(loop, fd, reading=reading)
        assert loop._fd_resources[fd] == key and key in native.leases
        assert others[fd] == original
        assert original[2] in loop._callbacks_by_cid
        assert len(loop._callbacks_by_cid) == 1
        assert not native.update_called and not native.pending
        assert not loop._fd_publications
    finally:
        loop.close()
        native.finish()
        left.close()
        right.close()


@pytest.mark.parametrize("reading", [True, False])
def test_shared_update_failure_quarantines_without_retiring_other_direction(
    reading: bool,
) -> None:
    loop = ErlangEventLoop()
    native = PublicationBoundary(loop)
    loop._pel = native
    left, right = socket.socketpair()
    try:
        fd = left.fileno()
        register(loop, fd, reading=not reading)
        key = loop._fd_resources[fd]
        native.failure = Failure.STOP
        with pytest.raises(FdRetirementError):
            register(loop, fd, reading=reading)
        assert key in native.leases and not native.pending
        assert loop._fd_resources[fd] == key
        publication = loop._fd_publications[fd]
        assert publication.key == key
        assert publication.phase == FdPublicationPhase.UPDATE_FAILED
        with pytest.raises(FdRetirementError):
            loop._close_socket(left)
        assert publication.closing_socket is left and left.fileno() == fd
        native.failure = Failure.NONE
        loop.close()
        assert not loop._readers and not loop._writers
        assert not loop._callbacks_by_cid and not loop._fd_publications
        assert left.fileno() == -1
    finally:
        native.failure = Failure.NONE
        loop.close()
        native.finish()
        left.close()
        right.close()


def test_slot_publication_failure_precedes_native_effect() -> None:
    loop = ErlangEventLoop()
    native = PublicationBoundary(loop)
    loop._pel = native
    loop._fd_publications = PublicationFailure[FdPublication]()
    left, right = socket.socketpair()
    try:
        with pytest.raises(MemoryError):
            register(loop, left.fileno(), reading=True)
        assert native.before_effect is None and not native.leases
        assert not loop._fd_publications and not loop._fd_resources
    finally:
        loop.close()
        native.finish()
        left.close()
        right.close()


def test_failed_shared_restore_keeps_owner_and_blocks_queued_old_callback() -> None:
    loop = ErlangEventLoop()
    native = PublicationBoundary(loop)
    loop._pel = native
    left, right = socket.socketpair()
    calls: list[str] = []
    try:
        fd = left.fileno()
        loop.add_reader(fd, calls.append, "old")
        old_id = loop._readers[fd][2]
        key = loop._fd_resources[fd]
        loop._dispatch(old_id, EVENT_TYPE_READ)
        loop._readers = PublicationFailure[FdWatcher](
            loop._readers,
            after_write=True,
            persistent=True,
        )
        with pytest.raises(MemoryError):
            loop.add_reader(fd, calls.append, "replacement")
        assert loop._fd_publications[fd].key == key
        assert loop._fd_resources[fd] == key and key in native.leases
        assert not native.update_called and not native.pending
        loop._ready.popleft()._run()
        assert calls == []
        loop.close()
        assert not loop._callbacks_by_cid and not loop._fd_publications
    finally:
        loop.close()
        native.finish()
        left.close()
        right.close()


@pytest.mark.parametrize("reading", [True, False])
def test_callback_publication_failure_rolls_back_a_new_native_lease(
    reading: bool,
) -> None:
    loop = ErlangEventLoop()
    native = PublicationBoundary(loop)
    loop._pel = native
    loop._callbacks_by_cid = PublicationFailure[FdCallback]()
    left, right = socket.socketpair()
    try:
        with pytest.raises(RuntimeError):
            register(loop, left.fileno(), reading=reading)
        assert not loop._fd_resources and not loop._fd_publications
        assert not native.leases and len(native.pending) == 1
    finally:
        loop.close()
        native.finish()
        left.close()
        right.close()

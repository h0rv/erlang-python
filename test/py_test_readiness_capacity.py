import asyncio
import errno
import os
import resource
import socket

import erlang
import py_event_loop as native
from _erlang_impl._loop import ErlangEventLoop


def owner() -> ErlangEventLoop:
    loop = asyncio.get_running_loop()
    assert isinstance(loop, ErlangEventLoop)
    return loop


async def poll_leases() -> bool | str:
    loop = owner()
    limits = resource.getrlimit(resource.RLIMIT_NOFILE)
    if limits[0] != resource.RLIM_INFINITY and limits[0] < 9000:
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (9000, limits[1]))
        except (OSError, ValueError) as error:
            return "Cannot raise RLIMIT_NOFILE to 9000 for 4352 poll leases: " + str(
                error
            )
    left, right = socket.socketpair()
    descriptors: list[int] = []
    delivered: set[int] = set()
    complete: asyncio.Future[None] = loop.create_future()

    def readable(fd: int) -> None:
        loop.remove_reader(fd)
        delivered.add(fd)
        if len(delivered) == 4352:
            complete.set_result(None)

    try:
        for _ in range(4352):
            fd = os.dup(left.fileno())
            descriptors.append(fd)
            loop.add_reader(fd, readable, fd)
        info = native._fd_poll_lease_info(loop._fd_resources[descriptors[-1]])
        assert info[4] >= 4352
        assert info[1] > 4096
        right.sendall(b"ready")
        async with asyncio.timeout(10):
            await complete
        assert len(delivered) == 4352
        assert not any(fd in loop._fd_resources for fd in descriptors)
    finally:
        for fd in descriptors:
            loop.remove_reader(fd)
            os.close(fd)
        left.close()
        right.close()
        resource.setrlimit(resource.RLIMIT_NOFILE, limits)
    return True


async def failed_dup() -> bool:
    loop = owner()
    try:
        native._add_reader_for(loop._loop_capsule, -1, native._new_fd_callback_id())
    except OSError as error:
        assert error.errno == errno.EBADF
    else:
        raise AssertionError("invalid descriptor was accepted")
    return True


async def reserved_events() -> bool:
    loop = owner()
    capsule = loop._loop_capsule
    channel = erlang.Channel.create_bytes(capacity=1, max_bytes=64)
    first = 10_000_000
    ordinary = 20_000_000
    try:
        for index in range(24000):
            assert not erlang._channel_ready(
                channel._ref, capsule, first + index, False, 0
            )
        for index in range(1000):
            erlang._channel_cancel_ready(channel._ref, first + index)
        for index in range(16385):
            native._add_pending(ordinary + index, "timer")
        channel.close()
        events = {callback for callback, _ in native._get_pending_for(capsule)}
        assert events == set(range(first + 1000, first + 24000)) | set(
            range(ordinary, ordinary + 16384)
        )
        for index in range(16385):
            native._add_pending(ordinary + index, "timer")
        assert len(native._run_once_native_for(capsule, 0)) == 16384
        native._add_pending(ordinary, "timer")
        assert [callback for callback, _ in native._get_pending_for(capsule)] == [
            ordinary
        ]
    finally:
        channel.close()
        native._get_pending_for(capsule)
    return True

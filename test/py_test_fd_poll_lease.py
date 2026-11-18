import asyncio
import fcntl
import os
import socket

import py_event_loop as native
from _erlang_impl._loop import EVENT_TYPE_READ, ErlangEventLoop


def owner() -> ErlangEventLoop:
    loop = asyncio.get_running_loop()
    assert isinstance(loop, ErlangEventLoop)
    return loop


async def borrowed() -> bool:
    loop = owner()
    left, right = socket.socketpair()
    left.setblocking(False)
    right.setblocking(False)
    callbacks: list[str] = []
    try:
        fd = left.fileno()
        original_flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        loop.add_reader(fd, callbacks.append, "stale")
        key = loop._fd_resources[fd]
        logical, poll, closing, selection, count = native._fd_poll_lease_info(key)
        assert logical == fd and poll != fd and closing == 0 and selection == 1
        assert count > 0 and not os.get_inheritable(poll)
        assert fcntl.fcntl(poll, fcntl.F_GETFL) == original_flags
        old_id = loop._readers[fd][2]
        loop._dispatch(old_id, EVENT_TYPE_READ)
        assert loop.remove_reader(fd)
        assert fcntl.fcntl(fd, fcntl.F_GETFL) == original_flags
        # Immediate reader and writer re-registration without a STOP wait.
        loop.add_reader(fd, callbacks.append, "also-stale")
        assert loop._readers[fd][2] != old_id
        assert loop.remove_reader(fd)
        loop.add_writer(fd, callbacks.append, "stale-writer")
        assert loop.remove_writer(fd)
        loop.add_reader(fd, callbacks.append, "shared-reader")
        shared_key = loop._fd_resources[fd]
        loop.add_writer(fd, callbacks.append, "shared-writer")
        assert loop._fd_resources[fd] == shared_key
        assert loop.remove_reader(fd)
        assert loop._fd_resources[fd] == shared_key
        assert loop.remove_writer(fd)
        left.close()
        replacement, peer = socket.socketpair()
        replacement.setblocking(False)
        peer.setblocking(False)
        try:
            assert replacement.fileno() == fd
            ready = loop.create_future()

            def readable() -> None:
                value = replacement.recv(3)
                loop.remove_reader(fd)
                ready.set_result(value)

            loop.add_reader(fd, readable)
            assert loop._readers[fd][2] != old_id
            loop._dispatch(old_id, EVENT_TYPE_READ)
            assert peer.send(b"new") == 3
            assert await ready == b"new"
            assert callbacks == []
            assert fd not in loop._fd_resources
        finally:
            replacement.close()
            peer.close()
    finally:
        loop._close_socket(left)
        right.close()
    return True


async def recv_completion() -> bool:
    loop = owner()
    left, right = socket.socketpair()
    left.setblocking(False)
    right.setblocking(False)
    try:
        fd = left.fileno()
        assert right.send(b"recv") == 4
        assert await loop.sock_recv(left, 4) == b"recv"
        assert fd not in loop._fd_resources and fd not in loop._readers
        os.fstat(fd)
        left.close()
    finally:
        loop._close_socket(left)
        right.close()
    return True


async def connect_completion() -> bool:
    loop = owner()
    server = socket.socket()
    client = socket.socket()
    server.setblocking(False)
    client.setblocking(False)
    try:
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        fd = client.fileno()
        before = native._new_fd_callback_id()
        await loop.sock_connect(client, server.getsockname())
        after = native._new_fd_callback_id()
        assert after > before + 1  # The native writer branch actually ran.
        assert fd not in loop._fd_resources and fd not in loop._writers
        accepted, _address = server.accept()
        accepted.close()
        client.close()
    finally:
        loop._close_socket(client)
        server.close()
    return True


async def callback_rearm() -> bool:
    loop = owner()
    left, right = socket.socketpair()
    left.setblocking(False)
    right.setblocking(False)
    pieces: list[bytes] = []
    done = loop.create_future()
    fd = left.fileno()

    def replacement() -> None:
        pieces.append(left.recv(1))
        if len(pieces) == 3:
            loop.remove_reader(fd)
            done.set_result(True)

    def readable() -> None:
        pieces.append(left.recv(1))
        loop.add_reader(fd, replacement)

    try:
        loop.add_reader(fd, readable)
        assert right.send(b"abc") == 3
        async with asyncio.timeout(2):
            await done
        assert pieces == [b"a", b"b", b"c"]
        assert fd not in loop._readers
        return True
    finally:
        loop._close_socket(left)
        right.close()

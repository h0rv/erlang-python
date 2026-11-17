import asyncio
import socket
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import override

import pytest
from _transport import ErlangSocketTransport


@dataclass
class Loop:
    writers: dict[int, Callable[[], None]] = field(default_factory=dict)
    failures: list[Mapping[str, object]] = field(default_factory=list)

    def add_writer(self, fd: int, callback: Callable[[], None]) -> None:
        self.writers[fd] = callback

    def _stop_writing(self, fd: int) -> None:
        self.writers.pop(fd, None)

    def _stop_reading(self, fd: int) -> None:
        pass

    def _close_socket(self, sock: socket.socket) -> None:
        self.writers.pop(sock.fileno(), None)
        sock.close()

    def call_exception_handler(self, context: Mapping[str, object]) -> None:
        self.failures.append(context)


class Protocol(asyncio.Protocol):
    def __init__(self) -> None:
        self.pauses = 0
        self.resumes = 0
        self.lost = 0

    @override
    def pause_writing(self) -> None:
        self.pauses += 1

    @override
    def resume_writing(self) -> None:
        self.resumes += 1

    @override
    def connection_lost(self, exc: Exception | None) -> None:
        self.lost += 1


def test_socket__stdlib_watermarks_pause_and_resume_after_partial_writes() -> None:
    loop, protocol = Loop(), Protocol()
    writer, reader = socket.socketpair()
    with writer, reader:
        writer.setblocking(False)
        reader.setblocking(False)
        writer.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024)
        transport = ErlangSocketTransport(loop, writer, protocol)
        transport.set_write_buffer_limits(high=8192, low=2048)
        assert transport.get_write_buffer_limits() == (2048, 8192)
        transport.write(b"x" * 131072)
        assert protocol.pauses == 1
        assert transport.get_write_buffer_size() > 8192
        for _ in range(1000):
            try:
                while reader.recv(65536):
                    pass
            except BlockingIOError:
                pass
            transport._write_ready_cb()
            if transport.get_write_buffer_size() == 0:
                break
        assert transport.get_write_buffer_size() == 0
        assert protocol.resumes == 1
        assert not loop.writers
        assert not loop.failures
        with pytest.raises(ValueError):
            transport.set_write_buffer_limits(high=1, low=2)
        transport.abort()
        assert protocol.lost == 1


def test_socket__fatal_write_aborts_buffered_transport_once() -> None:
    loop, protocol = Loop(), Protocol()
    writer, reader = socket.socketpair()
    with writer, reader:
        writer.setblocking(False)
        reader.close()
        transport = ErlangSocketTransport(loop, writer, protocol)
        transport.write(b"payload")
        assert writer.fileno() == -1
        assert protocol.lost == 1
        assert len(loop.failures) == 1
        transport.abort()
        assert protocol.lost == 1


class Received(asyncio.Protocol):
    def __init__(self) -> None:
        self.data: list[bytes] = []

    @override
    def data_received(self, data: bytes) -> None:
        self.data.append(data)


def test_socket__set_protocol_routes_later_reads_to_the_new_protocol() -> None:
    loop, first, second = Loop(), Received(), Received()
    writer, reader = socket.socketpair()
    with writer, reader:
        reader.setblocking(False)
        transport = ErlangSocketTransport(loop, reader, first)
        writer.sendall(b"upgrade")
        transport._read_ready()
        transport.set_protocol(second)
        writer.sendall(b"frame")
        transport._read_ready()
        assert transport.get_protocol() is second
        assert (first.data, second.data) == ([b"upgrade"], [b"frame"])

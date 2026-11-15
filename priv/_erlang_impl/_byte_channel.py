# Copyright 2026 Benoit Chesneau
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import asyncio

from _erlang_impl._channel import Channel, ChannelClosed
from _erlang_impl._loop import ErlangEventLoop


class ByteChannelClosed(Exception):
    pass


class ByteChannel:
    """Raw byte FIFO. Native async receive dequeues only in the receiving task.

    The compatibility executor path on non-native event loops is not cancellation
    safe. Use Channel.receive_bytes for strict native-only async reception.
    """

    __slots__ = ("_ref",)

    def __init__(self, channel_ref):
        self._ref = channel_ref

    def send_bytes(self, data: bytes | bytearray | memoryview) -> bool:
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise TypeError("data must be bytes, bytearray, or memoryview")
        Channel(self._ref).send_bytes_nowait(bytes(data))
        return True

    def try_receive_bytes(self) -> bytes | None:
        import erlang

        try:
            return erlang._byte_channel_try_receive_bytes(self._ref)
        except ChannelClosed as error:
            raise ByteChannelClosed("Channel closed") from error

    def receive_bytes(self, timeout_ms: int = -1) -> bytes:
        import erlang

        try:
            return erlang._byte_channel_receive_bytes(self._ref, timeout_ms)
        except ChannelClosed as error:
            raise ByteChannelClosed("Channel closed") from error

    def __iter__(self):
        while True:
            try:
                yield self.receive_bytes()
            except ByteChannelClosed:
                return

    async def async_receive_bytes(self) -> bytes:
        if isinstance(asyncio.get_running_loop(), ErlangEventLoop):
            try:
                return await Channel(self._ref).receive_bytes()
            except ChannelClosed as error:
                raise ByteChannelClosed("Channel closed") from error
        return await self._async_receive_polling()

    async def _async_receive_polling(self) -> bytes:
        loop = asyncio.get_running_loop()
        while True:
            try:
                return await loop.run_in_executor(None, lambda: self.receive_bytes(100))
            except TimeoutError:
                continue

    def __aiter__(self):
        return self

    async def __anext__(self) -> bytes:
        try:
            return await self.async_receive_bytes()
        except ByteChannelClosed:
            raise StopAsyncIteration from None

    def _is_closed(self) -> bool:
        return Channel(self._ref)._is_closed()

    def close(self) -> None:
        Channel(self._ref).close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False

    def __repr__(self):
        return "<ByteChannel ref={!r}>".format(self._ref)

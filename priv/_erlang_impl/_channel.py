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

"""
Bidirectional channel for Erlang-Python communication.

Channels provide efficient streaming message passing without syscall overhead.

Usage:

    # Receiving messages from Erlang (sync)
    def process_channel(channel_ref):
        from erlang.channel import Channel
        ch = Channel(channel_ref)

        # Blocking receive (suspends Python, yields to Erlang)
        msg = ch.receive()

        # Non-blocking receive
        msg = ch.try_receive()  # Returns None if empty

        # Iterate over messages
        for msg in ch:
            process(msg)

    # Async receiving (asyncio compatible)
    async def process_channel_async(channel_ref):
        from erlang.channel import Channel
        ch = Channel(channel_ref)

        # Async receive (yields to other coroutines while waiting)
        msg = await ch.async_receive()

        # Async iteration
        async for msg in ch:
            process(msg)

    # Sending replies to Erlang processes
    from erlang.channel import reply
    reply(pid, {"status": "ok", "data": result})
"""

from typing import Self

__all__ = ["Channel", "reply", "ChannelClosed", "ChannelAborted", "ChannelEmpty", "ChannelOverloaded",
           "UnsupportedChannelRuntime"]

# A valid native wait result may contain None; only this identity means retry.
_RETRY_RECEIVE = object()


class ChannelClosed(RuntimeError):
    """Raised when attempting to receive from a closed channel."""

    pass


class ChannelAborted(RuntimeError):
    pass


class ChannelOverloaded(RuntimeError):
    pass


class ChannelEmpty(RuntimeError):
    pass


class UnsupportedChannelRuntime(RuntimeError):
    pass


class Channel:
    """Bidirectional channel for Erlang-Python communication.

    Channels wrap an Erlang channel reference and provide a Pythonic
    interface for receiving messages and iterating over them.

    Attributes:
        _ref: The underlying Erlang channel reference.
    """

    __slots__ = ("_ref",)

    def __init__(self, channel_ref):
        """Initialize a channel wrapper.

        Args:
            channel_ref: The Erlang channel reference from py_channel:new/0.
        """
        self._ref = channel_ref

    def receive(self, timeout_ms=-1):
        """Receive the next message from the channel.

        This is a blocking receive that waits for data. The GIL is released
        while waiting, allowing other Python threads to run.

        Args:
            timeout_ms: Timeout in milliseconds (-1 = infinite, default)

        Returns:
            The received Erlang term, converted to Python.

        Raises:
            ChannelClosed: If the channel has been closed.
            TimeoutError: If timeout expires before data arrives.
        """
        import erlang

        # Direct NIF call - no erlang.call() roundtrip
        return erlang._channel_receive(self._ref, timeout_ms)

    def try_receive(self):
        """Try to receive a message without blocking.

        Returns:
            The received message, or None if the channel is empty.

        Raises:
            ChannelClosed: If the channel has been closed.
        """
        import erlang

        # Direct NIF call - no erlang.call() roundtrip
        return erlang._channel_try_receive(self._ref)

    def __iter__(self):
        """Iterate over messages until the channel is closed.

        Yields:
            Each message received from the channel.

        Example:
            for msg in channel:
                process(msg)
        """
        while True:
            try:
                yield self.receive()
            except ChannelClosed:
                break

    # ========================================================================
    # Async methods (asyncio compatible)
    # ========================================================================

    async def async_receive(self, *, native_only: bool = False):
        """Async receive - yields to other coroutines while waiting.

        This method uses event-driven notification when running on ErlangEventLoop.
        When data arrives, the channel notifies the event loop via timer dispatch,
        avoiding polling overhead.

        Falls back to the legacy executor path only on non-Erlang event loops,
        unless native_only is True. That compatibility path is not cancellation safe.

        Native callbacks signal readiness only. Dequeue occurs in the receiving
        task with no intervening await before returning the delivery.

        Args:
            native_only: Require native dispatch, even when data is already
                queued. Empty notifications re-register the native waiter
                instead of falling back to polling. Defaults to False.

        Returns:
            The received Erlang term, converted to Python.

        Raises:
            ChannelClosed: If the channel has been closed.
            RuntimeError: If native_only is True and the loop lacks native dispatch.

        Example:
            msg = await channel.async_receive(native_only=True)
        """
        import asyncio

        from _erlang_impl._loop import ErlangEventLoop

        loop = asyncio.get_running_loop()
        native_dispatch = isinstance(loop, ErlangEventLoop)
        if native_only and not native_dispatch:
            raise UnsupportedChannelRuntime("native_only=True requires an ErlangEventLoop")

        # Try non-blocking first (direct NIF - fast)
        import erlang

        empty, result = erlang._channel_term_result(self._ref)
        if not empty:
            return result

        if native_dispatch:
            while True:
                result = await self._async_receive_event_driven(loop)
                if result is not _RETRY_RECEIVE:
                    return result
                # Another consumer may have drained the notification's data.
                # Always re-register native readiness; never dequeue in a worker.
        else:
            # Fallback for non-Erlang event loops: use polling
            return await self._async_receive_polling()

    async def _async_receive_event_driven(self, loop):
        """Event-driven async receive using channel waiter mechanism.

        Registers for EVENT_TYPE_TIMER readiness, never delivery. Empty
        notifications return _RETRY_RECEIVE. Tagged native receive results
        distinguish an empty queue from a valid None payload.
        """
        import asyncio
        import asyncio.events

        import erlang

        future = loop.create_future()
        callback_id = id(future)

        # Callback that fires when channel has data
        def on_channel_ready():
            if future.done():
                return
            future.set_result(None)

        # Create handle and register in timer dispatch system
        # Only use _timers dict - don't touch _handle_to_callback_id (for timer cancellation only)
        handle = asyncio.events.Handle(on_channel_ready, (), loop)
        loop._timers[callback_id] = handle

        try:
            # Register waiter with channel (direct C call, no Erlang overhead)
            ready = erlang._channel_ready(self._ref, loop._loop_capsule, callback_id, False, 0)
            if not ready:
                await future
            empty, data = erlang._channel_term_result(self._ref)
            return _RETRY_RECEIVE if empty else data
        finally:
            loop._timers.pop(callback_id, None)
            erlang._channel_cancel_ready(self._ref, callback_id)

    async def _async_receive_polling(self):
        """Fallback async receive for non-Erlang event loops.

        Uses run_in_executor to run blocking receive in a thread pool,
        avoiding busy-polling while still releasing the event loop.
        """
        import asyncio

        import erlang

        loop = asyncio.get_running_loop()

        # Run blocking receive in thread pool (releases GIL, waits on condition var)
        # Use 100ms timeout chunks to allow cancellation checks
        while True:
            try:
                result = await loop.run_in_executor(
                    None,
                    lambda: erlang._channel_receive(self._ref, 100),  # 100ms timeout
                )
                return result
            except TimeoutError:
                # Check for cancellation, then retry
                await asyncio.sleep(0)
                continue

    def __aiter__(self):
        """Return async iterator for the channel.

        Example:
            async for msg in channel:
                process(msg)
        """
        return self

    async def __anext__(self):
        """Get next message asynchronously.

        Raises:
            StopAsyncIteration: When the channel is closed.
        """
        try:
            return await self.async_receive()
        except ChannelClosed:
            raise StopAsyncIteration from None

    def _is_closed(self):
        """Check if the channel is closed."""
        import erlang

        return erlang._channel_is_closed(self._ref)

    def close(self):
        """Close the channel.

        Closes the channel and wakes any waiting receivers with ChannelClosed.
        Safe to call multiple times - subsequent calls have no effect.

        Example:
            channel.close()  # Signal no more data
        """
        import erlang

        erlang._channel_close(self._ref)

    @classmethod
    def create_bytes(cls, *, capacity: int, max_bytes: int) -> Self:
        import erlang

        return cls(erlang._channel_create_bounded(capacity, max_bytes))

    def send_bytes_nowait(self, payload: bytes) -> None:
        import erlang

        result = erlang._channel_send_result(self._ref, payload)
        if result == "full":
            raise ChannelOverloaded("Queued payload limit reached")
        if result == "closed":
            raise ChannelClosed("Channel closed")

    def receive_bytes_nowait(self) -> bytes:
        import erlang

        status, payload = erlang._channel_receive_result(self._ref)
        if status == "empty":
            raise ChannelEmpty("Channel empty")
        if status == "closed":
            raise ChannelClosed("Channel closed")
        if status == "aborted":
            raise ChannelAborted("Channel aborted; queued payloads discarded")
        return payload

    async def wait_ready(self, *, writing: bool = False, size: int = 0) -> None:
        import asyncio
        import erlang
        from _erlang_impl._loop import ErlangEventLoop

        loop = asyncio.get_running_loop()
        if not isinstance(loop, ErlangEventLoop):
            raise UnsupportedChannelRuntime("PyBEAM channels require ErlangEventLoop")
        future = loop.create_future()
        callback_id = id(future)

        def ready() -> None:
            if not future.done():
                future.set_result(None)

        loop._timers[callback_id] = asyncio.Handle(ready, (), loop)
        try:
            if not erlang._channel_ready(self._ref, loop._loop_capsule, callback_id, writing, size):
                await future
        finally:
            loop._timers.pop(callback_id, None)
            erlang._channel_cancel_ready(self._ref, callback_id)

    async def receive_bytes(self) -> bytes:
        self.require_native_loop()
        while True:
            try:
                return self.receive_bytes_nowait()
            except ChannelEmpty:
                await self.wait_ready()

    @staticmethod
    def require_native_loop() -> None:
        import asyncio
        from _erlang_impl._loop import ErlangEventLoop

        if not isinstance(asyncio.get_running_loop(), ErlangEventLoop):
            raise UnsupportedChannelRuntime("PyBEAM channels require ErlangEventLoop")

    def abort(self) -> None:
        import erlang

        erlang._channel_abort(self._ref)

    def snapshot(self) -> tuple[int, int, int, int, bool, int]:
        import erlang

        return erlang._channel_snapshot(self._ref)

    def __enter__(self):
        """Context manager entry - returns self."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - closes the channel."""
        self.close()
        return False

    def __repr__(self):
        return "<Channel ref={!r}>".format(self._ref)


def reply(pid, term):
    """Send a reply to an Erlang process.

    This allows Python code to send messages back to Erlang processes
    via enif_send, enabling bidirectional communication.

    Args:
        pid: The Erlang PID to send to (from erlang.self() or passed in).
        term: The Python value to send (will be converted to Erlang term).

    Returns:
        True on success.

    Raises:
        RuntimeError: If the send fails.

    Example:
        # Python handler receives a request with the sender's PID
        def handle_request(request):
            sender_pid = request['reply_to']
            result = compute_something()
            reply(sender_pid, {'status': 'ok', 'result': result})
    """
    import erlang

    # Use erlang.send for fire-and-forget message sending
    # This directly calls enif_send without requiring callback handling
    result = erlang.send(pid, term)

    if result == "ok" or result is True:
        return True
    elif isinstance(result, tuple) and result[0] == "error":
        raise RuntimeError("Reply failed: {}".format(result[1]))
    else:
        return True

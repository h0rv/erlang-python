"""Focused native_only regression probes, executed inside the real Erlang NIF.

Run with test/native_receive_option_probe.erl. No runtime monkeypatches are used.
"""

import asyncio
import sys

import erlang
from erlang import Channel, ChannelClosed


class ReceiveProbe(Channel):
    """Observe real registrations and fallback calls without replacing either."""

    def __init__(self, ref: object) -> None:
        super().__init__(ref)
        self.registrations = 0
        self.polling_calls = 0
        self.registered = asyncio.Event()
        self.polling_started = asyncio.Event()

    async def _async_receive_event_driven(self, loop):
        self.registrations += 1
        self.registered.set()
        return await super()._async_receive_event_driven(loop)

    async def _async_receive_polling(self):
        self.polling_calls += 1
        self.polling_started.set()
        return await super()._async_receive_polling()

    async def wait_registered(self, count: int) -> None:
        while self.registrations < count:
            await self.registered.wait()
            self.registered.clear()


def send(ref: object, payload: bytes) -> None:
    # The existing private send API takes an Erlang external-term binary.
    # {bytes, Payload} avoids the runtime's UTF-8 binary-to-str conversion.
    encoded = b"\x83h\x02w\x05bytesm" + len(payload).to_bytes(4, "big") + payload
    assert erlang._channel_send(ref, encoded) is True


async def unsupported(ref: object, queued: bool = False) -> bool:
    channel = ReceiveProbe(ref)
    if queued:
        send(ref, b"queued")
    try:
        await channel.async_receive(native_only=True)
    except RuntimeError as exc:
        assert "ErlangEventLoop" in str(exc)
    else:
        raise AssertionError("ordinary asyncio loop accepted native_only=True")
    assert channel.polling_calls == 0
    assert channel.registrations == 0
    if queued:
        assert await channel.async_receive() == b"queued"
    return True


async def ordinary_fallback(ref: object) -> bool:
    channel = ReceiveProbe(ref)
    async with asyncio.timeout(3), asyncio.TaskGroup() as group:
        task = group.create_task(channel.async_receive())
        await channel.polling_started.wait()
        send(ref, b"executor")
        assert await task == b"executor"
    assert channel.polling_calls == 1
    return True


async def immediate(ref: object) -> bool:
    channel = ReceiveProbe(ref)
    send(ref, b"immediate")
    assert await channel.async_receive(native_only=True) == b"immediate"
    assert channel.registrations == channel.polling_calls == 0
    return True


async def delayed(ref: object) -> bool:
    channel = ReceiveProbe(ref)
    async with asyncio.timeout(3), asyncio.TaskGroup() as group:
        task = group.create_task(channel.async_receive(native_only=True))
        await channel.wait_registered(1)
        send(ref, b"delayed")
        assert await task == b"delayed"
    assert channel.registrations == 1
    assert channel.polling_calls == 0
    return True


async def spurious(ref: object, native_only: bool) -> bool:
    channel = ReceiveProbe(ref)
    async with asyncio.timeout(5), asyncio.TaskGroup() as group:
        task = group.create_task(channel.async_receive(native_only=native_only))
        await channel.wait_registered(1)
        # Enqueue a real native notification, then consume its message before
        # the event loop dispatches it. The waiting callback must find no data.
        count = 1100 if native_only else 1
        for index in range(count):
            send(ref, b"stolen")
            assert channel.try_receive() == b"stolen"
            if native_only:
                await channel.wait_registered(index + 2)
            else:
                await channel.polling_started.wait()
        send(ref, b"after-spurious")
        assert await task == b"after-spurious"
    assert channel.registrations == (count + 1 if native_only else 1)
    assert channel.polling_calls == (0 if native_only else 1)
    return True


async def cancellation(ref: object, after_spurious: bool = False) -> bool:
    channel = ReceiveProbe(ref)
    loop = asyncio.get_running_loop()
    async with asyncio.timeout(3), asyncio.TaskGroup() as group:
        initial_timers = set(loop._timers)
        task = group.create_task(channel.async_receive(native_only=True))
        await channel.wait_registered(1)
        if after_spurious:
            send(ref, b"stolen")
            assert channel.try_receive() == b"stolen"
            await channel.wait_registered(2)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("receive did not propagate cancellation")
        assert set(loop._timers) == initial_timers
        # A second empty receive must register, not fail with waiter_exists.
        registrations = channel.registrations
        next_task = group.create_task(channel.async_receive(native_only=True))
        await channel.wait_registered(registrations + 1)
        send(ref, b"after-cancel")
        assert await next_task == b"after-cancel"
        assert set(loop._timers) == initial_timers
    assert channel.polling_calls == 0
    return True


async def closure(ref: object) -> bool:
    channel = ReceiveProbe(ref)

    async def receive_closed() -> bool:
        try:
            await channel.async_receive(native_only=True)
        except ChannelClosed:
            return True
        raise AssertionError("closing a waiting channel did not wake it")

    async with asyncio.timeout(3), asyncio.TaskGroup() as group:
        task = group.create_task(receive_closed())
        await channel.wait_registered(1)
        channel.close()
        assert await task is True
    assert channel.polling_calls == 0
    return True


async def closed_drain(ref: object) -> bool:
    channel = ReceiveProbe(ref)
    send(ref, b"drain")
    channel.close()
    assert await channel.async_receive(native_only=True) == b"drain"
    try:
        await channel.async_receive(native_only=True)
    except ChannelClosed:
        pass
    else:
        raise AssertionError("drained closed channel did not raise")
    return True


async def duplicate_waiter(ref: object) -> bool:
    channel = ReceiveProbe(ref)
    loop = asyncio.get_running_loop()
    async with asyncio.timeout(3), asyncio.TaskGroup() as group:
        task = group.create_task(channel.async_receive(native_only=True))
        await channel.wait_registered(1)
        initial_timers = set(loop._timers)
        try:
            await Channel(ref).async_receive(native_only=True)
        except RuntimeError as exc:
            assert "waiter_exists" in str(exc)
        else:
            raise AssertionError("duplicate waiter was accepted")
        assert set(loop._timers) == initial_timers
        send(ref, b"original-waiter")
        assert await task == b"original-waiter"
    assert channel.polling_calls == 0
    return True


def run_case(name: str, ref: object) -> bool:
    match name:
        case "unsupported_empty":
            return asyncio.run(unsupported(ref))
        case "unsupported_queued":
            return asyncio.run(unsupported(ref, queued=True))
        case "ordinary_fallback":
            return asyncio.run(ordinary_fallback(ref))
        case "immediate":
            return erlang.run(immediate(ref))
        case "delayed":
            return erlang.run(delayed(ref))
        case "native_spurious":
            return erlang.run(spurious(ref, native_only=True))
        case "default_spurious":
            return erlang.run(spurious(ref, native_only=False))
        case "cancellation":
            return erlang.run(cancellation(ref))
        case "cancellation_after_spurious":
            return erlang.run(cancellation(ref, after_spurious=True))
        case "closure":
            return erlang.run(closure(ref))
        case "closed_drain":
            return erlang.run(closed_drain(ref))
        case "duplicate_waiter":
            return erlang.run(duplicate_waiter(ref))
        case _:
            raise ValueError(name)


def environment() -> tuple[str, str]:
    return sys.version, sys.modules[Channel.__module__].__file__

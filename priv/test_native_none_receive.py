"""Real native arrival-window regression for a valid None channel payload."""

import asyncio

import erlang


class NativeNoneProbe(erlang.Channel):
    """Inject ETF none after the empty fast path, before native registration."""

    def __init__(self, ref: object) -> None:
        super().__init__(ref)
        self.initial_receive_seen = False
        self.registrations = 0
        self.polling_calls = 0

    def try_receive(self) -> object:
        result = super().try_receive()
        if not self.initial_receive_seen:
            self.initial_receive_seen = True
            assert result is None
            # SMALL_ATOM_UTF8_EXT none converts to Python None in the real NIF.
            assert erlang._channel_send(self._ref, b"\x83w\x04none") is True
        return result

    async def _async_receive_event_driven(self, loop):
        self.registrations += 1
        return await super()._async_receive_event_driven(loop)

    async def _async_receive_polling(self):
        self.polling_calls += 1
        return await super()._async_receive_polling()


async def arrival_window(ref: object, *, native_only: bool) -> bool:
    channel = NativeNoneProbe(ref)
    loop = asyncio.get_running_loop()
    initial_timers = set(loop._timers)
    async with asyncio.timeout(1):
        assert await channel.async_receive(native_only=native_only) is None
    assert channel.initial_receive_seen
    assert channel.registrations == 1
    assert channel.polling_calls == 0
    assert set(loop._timers) == initial_timers
    # None was consumed exactly once; subsequent bytes still arrive unchanged.
    payload = b"after-none"
    encoded = b"\x83h\x02w\x05bytesm" + len(payload).to_bytes(4, "big") + payload
    assert erlang._channel_send(ref, encoded) is True
    assert await channel.async_receive(native_only=native_only) == payload
    assert channel.registrations == 1
    assert channel.polling_calls == 0
    return True


def run_case(ref: object, *, native_only: bool) -> bool:
    return erlang.run(arrival_window(ref, native_only=native_only))

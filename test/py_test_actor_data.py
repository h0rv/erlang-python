import asyncio
from contextlib import suppress

import erlang
from erlang.actors import ActorGenerationChanged, ActorOverloaded, DataActorGroup


class Counter:
    def __init__(self, initial: int = 0) -> None:
        self.value = initial

    async def dispatch(self, payload: bytes) -> bytes:
        if payload == b"wait":
            loop = asyncio.get_running_loop()
            loop.add_reader(
                erlang._get_async_callback_fd(), erlang._async_callback_reader
            )
            await erlang.async_call("actor_data_gate")
        else:
            self.value += int(payload)
        return str(self.value).encode()


def reserve(gate: object, size: int) -> object:
    return erlang._actor_reserve(gate, size)


def abort(ticket: object) -> None:
    erlang._actor_abort(ticket)


def enqueue(pid: object, gate: object, ticket: object, payload: bytes) -> int:
    erlang._get_async_callback_fd()
    return erlang._send_async_request("_actor_data_call", (pid, gate, ticket, payload))


async def run_basic() -> bool:
    loop = asyncio.get_running_loop()
    loop.add_reader(erlang._get_async_callback_fd(), erlang._async_callback_reader)
    async with DataActorGroup(max_children=1) as group:
        ref = await group.spawn("counter", lambda: Counter(7), capacity=2, max_bytes=4)
        assert await ref.call(b"2") == b"9"
        first = ref.reserve(b"1")
        second = ref.reserve(b"1")
        try:
            ref.reserve(b"0")
        except ActorOverloaded:
            pass
        else:
            raise AssertionError("Count reservation was not shared")
        first.abort()
        second.abort()
        aliases = [await ref.rejoin() for _ in range(24)]
        accepted = []
        rejected = 0
        for alias in aliases:
            try:
                accepted.append(alias.reserve(b"1"))
            except ActorOverloaded:
                rejected += 1
        assert len(accepted) == 2
        assert rejected == 22
        for ticket in accepted:
            ticket.abort()
        first = ref.reserve(b"123")
        try:
            ref.reserve(b"12")
        except ActorOverloaded:
            pass
        else:
            raise AssertionError("Aggregate byte reservation exceeded")
        first.abort()
        too_large = b"12345"
        try:
            ref.reserve(too_large)
        except ActorOverloaded:
            pass
        else:
            raise AssertionError("Byte reservation exceeded")
        abandoned = ref.reserve(b"1")
        abandoned.abort()
        try:
            await abandoned.send()
        except RuntimeError:
            pass
        else:
            raise AssertionError("Aborted payload executed")
        assert await ref.call(b"0") == b"9"
        try:
            await group.spawn("other", Counter)
        except RuntimeError:
            pass
        else:
            raise AssertionError("Child bound exceeded")
        await group.stop("counter")
        fresh = await group.spawn("counter", Counter)
        assert await fresh.call(b"0") == b"0"
    return True


async def run_cancelled() -> bool:
    loop = asyncio.get_running_loop()
    loop.add_reader(erlang._get_async_callback_fd(), erlang._async_callback_reader)
    async with DataActorGroup() as group:
        ref = await group.spawn("counter", Counter, capacity=1, max_bytes=4)
        pending = asyncio.create_task(ref.call(b"wait"))
        await erlang.async_call("actor_data_entered")
        pending.cancel()
        with suppress(asyncio.CancelledError):
            await pending
        try:
            ref.reserve(b"1")
        except ActorOverloaded:
            pass
        else:
            raise AssertionError("Cancellation released running work")
        await erlang.async_call("actor_data_release")
        # This control callback joins the actor call, so the real completion
        # precedes the next reservation without timing assumptions.
        await erlang.async_call("actor_data_join", ref.pid)
        assert await ref.call(b"1") == b"1"
    return True


async def run_restart() -> bool:
    loop = asyncio.get_running_loop()
    loop.add_reader(erlang._get_async_callback_fd(), erlang._async_callback_reader)
    async with DataActorGroup() as group:
        ref = await group.spawn("counter", lambda: Counter(5))
        assert await ref.call(b"2") == b"7"
        await erlang.async_call("actor_data_kill", ref.pid)
        try:
            await ref.call(b"1")
        except ActorGenerationChanged as error:
            assert error.current != error.expected
        else:
            raise AssertionError("Old logical generation silently replayed")
        fresh = await ref.rejoin()
        assert fresh.pid != ref.pid
        assert await fresh.call(b"0") == b"5"
    return True


def basic() -> bool:
    return asyncio.run(run_basic())


def cancelled() -> bool:
    return asyncio.run(run_cancelled())


def restart() -> bool:
    return asyncio.run(run_restart())

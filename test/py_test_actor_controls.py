import asyncio
from contextlib import suppress
from dataclasses import dataclass

from erlang.actors import (
    ActorGenerationChanged,
    ActorOverloaded,
    DataActorGroup,
    context_counts,
)


@dataclass
class Echo:
    async def dispatch(self, payload: bytes, /) -> bytes:
        if payload == b"wait":
            await asyncio.sleep(0.3)
        return payload


async def generations() -> bool:
    before = await context_counts()
    async with DataActorGroup(max_children=1) as group:
        old = await group.spawn("echo", Echo, capacity=1, max_bytes=4)
        initial = await old.info()
        assert initial.pid.startswith("<") and initial.pid.endswith(">")
        assert initial.generation == old.generation
        assert (initial.admitted_count, initial.admitted_bytes) == (0, 0)
        ticket = old.reserve(b"x")
        info = await old.info()
        assert (info.admitted_count, info.admitted_bytes) == (1, 1)
        ticket.abort()
        await old.crash()
        fresh = await old.rejoin()
        final = await fresh.info()
        assert final.pid != initial.pid
        assert final.generation != initial.generation
        for operation in (old.crash, old.info):
            try:
                await operation()
            except ActorGenerationChanged as error:
                assert error.expected == initial.generation
                assert error.current == final.generation
            else:
                raise AssertionError("Stale diagnostic affected a replacement")
        assert await fresh.info() == final
        assert await fresh.call(b"ok") == b"ok"
    assert (await context_counts()).live == before.live
    return True


async def cancelled_body() -> bool:
    before = await context_counts()
    async with DataActorGroup(max_children=1) as group:
        actor = await group.spawn("echo", Echo, capacity=1, max_bytes=4)
        async with asyncio.TaskGroup() as calls:
            pending = calls.create_task(actor.call(b"wait"))
            async with asyncio.timeout(5):
                while (await actor.info()).admitted_count == 0:
                    await asyncio.sleep(0)
            pending.cancel()
            with suppress(asyncio.CancelledError):
                await pending
            info = await actor.info()
            assert (info.admitted_count, info.admitted_bytes) == (1, 4)
            try:
                actor.reserve(b"x")
            except ActorOverloaded:
                pass
            else:
                raise AssertionError("Cancelled waiter released native body credits")
            await actor.crash()
        fresh = await actor.rejoin()
        info = await fresh.info()
        assert (info.admitted_count, info.admitted_bytes) == (0, 0)
        assert await fresh.call(b"ok") == b"ok"
    assert (await context_counts()).live == before.live
    return True


async def temporary_fault() -> bool:
    before = await context_counts()
    async with DataActorGroup(max_children=1) as group:
        actor = await group.spawn("temporary", Echo, restart="temporary")
        async with asyncio.timeout(2):
            await actor.crash()
        replacement = await group.spawn("temporary", Echo, restart="temporary")
        assert replacement.generation != actor.generation
        assert await replacement.call(b"ok") == b"ok"
    assert (await context_counts()).live == before.live
    return True


async def crash_cancelled() -> bool:
    before = await context_counts()
    async with DataActorGroup(max_children=1) as group:
        actor = await group.spawn("echo", Echo, capacity=1, max_bytes=4)
        async with asyncio.TaskGroup() as tasks:
            call = tasks.create_task(actor.call(b"wait"))
            async with asyncio.timeout(5):
                while (await actor.info()).admitted_count == 0:
                    await asyncio.sleep(0)
            call.cancel()
            with suppress(asyncio.CancelledError):
                await call
            crash = tasks.create_task(actor.crash())
            await asyncio.sleep(0.01)
            crash.cancel()
            with suppress(asyncio.CancelledError):
                await crash
        fresh = await actor.rejoin()
        assert fresh.generation != actor.generation
        assert (await fresh.info()).admitted_count == 0
        assert await fresh.call(b"ok") == b"ok"
    assert (await context_counts()).live == before.live
    return True


async def close_cancelled() -> bool:
    before = await context_counts()
    ready = asyncio.Event()

    async def owner() -> None:
        async with DataActorGroup(max_children=2) as group:
            refs = [await group.spawn(str(i), Echo) for i in range(2)]
            async with asyncio.TaskGroup() as calls:
                for ref in refs:
                    calls.create_task(ref.call(b"wait"))
                async with asyncio.timeout(5):
                    for ref in refs:
                        while (await ref.info()).admitted_count == 0:
                            await asyncio.sleep(0)
                ready.set()
                await asyncio.Event().wait()

    async with asyncio.timeout(10), asyncio.TaskGroup() as tasks:
        pending = tasks.create_task(owner())
        await ready.wait()
        pending.cancel()
        with suppress(asyncio.CancelledError):
            await pending
    assert (await context_counts()).live == before.live
    return True

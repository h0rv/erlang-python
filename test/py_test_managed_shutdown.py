import asyncio
from collections.abc import AsyncGenerator
from dataclasses import dataclass, field

import erlang
from erlang.channel import Channel


async def checkpoint() -> None:
    loop = asyncio.get_running_loop()
    ready = loop.create_future()
    loop.call_soon(ready.set_result, None)
    await ready


@dataclass
class Owners:
    loop: asyncio.AbstractEventLoop
    queued: Channel
    waiting: Channel
    tasks: list[asyncio.Task[None]] = field(default_factory=list)
    finalized: set[str] = field(default_factory=set)
    generators: list[AsyncGenerator[int]] = field(default_factory=list)
    release: asyncio.Event = field(default_factory=asyncio.Event)
    cancellation_seen: asyncio.Event = field(default_factory=asyncio.Event)


@dataclass
class Inspection:
    owners: Owners | None = None


_inspection = Inspection()


def state() -> Owners:
    owners = _inspection.owners
    if owners is None:
        raise RuntimeError("Shutdown test owners were not prepared")
    return owners


async def setup() -> str:
    owners = Owners(
        asyncio.get_running_loop(),
        Channel.create_bytes(capacity=64, max_bytes=1048576),
        Channel.create_bytes(capacity=64, max_bytes=1048576),
    )
    _inspection.owners = owners

    async def successor() -> None:
        try:
            await asyncio.Event().wait()
        finally:
            await checkpoint()
            owners.finalized.add("successor")

    async def queued_owner() -> None:
        owners.queued.send_bytes_nowait(b"queued")
        try:
            await asyncio.Event().wait()
        finally:
            await checkpoint()
            owners.tasks.append(asyncio.create_task(successor()))
            owners.queued.abort()
            owners.finalized.add("queued")

    async def waiting_owner() -> None:
        try:
            await owners.waiting.receive_bytes()
        finally:
            await checkpoint()
            owners.waiting.abort()
            owners.finalized.add("waiting")

    async def child() -> None:
        try:
            await asyncio.Event().wait()
        finally:
            await checkpoint()
            await checkpoint()
            owners.finalized.add("child")

    async def grouped() -> None:
        async with asyncio.TaskGroup() as group:
            owners.tasks.append(group.create_task(child()))
            await asyncio.Event().wait()

    async def generator() -> AsyncGenerator[int]:
        try:
            yield 1
        finally:
            await checkpoint()
            owners.finalized.add("generator")

    owners.tasks.extend(
        asyncio.create_task(owner()) for owner in (queued_owner, waiting_owner, grouped)
    )
    retained = generator()
    owners.generators.append(retained)
    assert await anext(retained) == 1
    await checkpoint()
    await checkpoint()
    assert owners.queued.snapshot() == (1, 6, 64, 1048576, False, 0)
    assert owners.waiting.snapshot() == (0, 0, 64, 1048576, False, 1)
    return "prepared"


def assert_clean() -> bool:
    owners = state()
    assert owners.loop.is_closed()
    assert owners.queued.snapshot() == (0, 0, 64, 1048576, True, 0)
    assert owners.waiting.snapshot() == (0, 0, 64, 1048576, True, 0)
    assert all(task.done() for task in owners.tasks)
    assert owners.finalized == {"queued", "waiting", "child", "successor", "generator"}
    return True


async def assert_running() -> bool:
    owners = state()
    assert not owners.loop.is_closed()
    assert owners.queued.snapshot() == (1, 6, 64, 1048576, False, 0)
    assert owners.waiting.snapshot() == (0, 0, 64, 1048576, False, 1)
    assert not any(task.done() for task in owners.tasks)
    return True


async def setup_resistant(owner: object) -> str:
    owners = Owners(
        asyncio.get_running_loop(),
        Channel.create_bytes(capacity=64, max_bytes=1048576),
        Channel.create_bytes(capacity=64, max_bytes=1048576),
    )
    _inspection.owners = owners

    async def resistant() -> None:
        owners.queued.send_bytes_nowait(b"queued")
        try:
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                owners.cancellation_seen.set()
                erlang.send(owner, "cancellation-seen")
                await owners.release.wait()
        finally:
            await checkpoint()
            owners.queued.abort()
            owners.waiting.abort()

    owners.tasks.append(asyncio.create_task(resistant()))
    await checkpoint()
    return "prepared"


async def assert_retained() -> bool:
    owners = state()
    assert owners.cancellation_seen.is_set()
    assert not owners.loop.is_closed()
    assert not owners.tasks[0].done()
    assert owners.tasks[0].cancelling() == 1
    assert owners.queued.snapshot() == (1, 6, 64, 1048576, False, 0)
    return True


async def release() -> str:
    state().release.set()
    return "released"


def assert_released() -> bool:
    owners = state()
    assert owners.loop.is_closed()
    assert all(task.done() for task in owners.tasks)
    assert owners.queued.snapshot() == (0, 0, 64, 1048576, True, 0)
    assert owners.waiting.snapshot() == (0, 0, 64, 1048576, True, 0)
    return True


async def setup_failed_cleanup() -> str:
    await setup()

    async def failed() -> None:
        try:
            await asyncio.Event().wait()
        finally:
            await checkpoint()
            raise ValueError("cleanup failed")

    state().tasks.append(asyncio.create_task(failed()))
    await checkpoint()
    return "prepared"

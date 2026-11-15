import asyncio
from collections.abc import AsyncGenerator, Coroutine
from contextvars import Context, ContextVar
from dataclasses import dataclass, field
from enum import StrEnum

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


class Timing(StrEnum):
    BEFORE_SCAN = "before_scan"
    DURING_WAIT = "during_wait"
    FINAL_TURN = "final_turn"


@dataclass
class Successors:
    loop: asyncio.AbstractEventLoop
    channel: Channel
    fail: bool
    timing: Timing
    tasks: list[asyncio.Task[None]] = field(default_factory=list)
    factory: object = None
    requested: list[Context] = field(default_factory=list)
    received: list[Context] = field(default_factory=list)


@dataclass
class SuccessorInspection:
    owners: Successors | None = None


_successors = SuccessorInspection()
_marker: ContextVar[str] = ContextVar("shutdown_context", default="unset")


async def setup_successors(
    timing: str, fail: bool, eager: bool, nested: bool, custom_factory: bool
) -> str:
    loop = asyncio.get_running_loop()
    owners = Successors(loop, Channel.create_bytes(capacity=1, max_bytes=1), fail, Timing(timing))
    _successors.owners = owners
    owners.channel.send_bytes_nowait(b"x")

    def factory(
        target: asyncio.AbstractEventLoop,
        coro: Coroutine[object, object, object],
        *,
        context: Context | None = None,
        eager_start: bool = False,
    ) -> asyncio.Task[object]:
        if context is not None:
            owners.received.append(context)
        return asyncio.Task(coro, loop=target, context=context, eager_start=eager_start)

    if custom_factory:
        loop.set_task_factory(factory)
    owners.factory = loop.get_task_factory()

    async def leaf() -> None:
        assert _marker.get() == "explicit"
        if owners.fail:
            raise ValueError("sensitive cleanup payload")
        owners.channel.abort()

    def create(coro: Coroutine[object, object, None]) -> None:
        context = Context()
        context.run(_marker.set, "explicit")
        owners.requested.append(context)
        created = loop.create_task(coro, context=context, eager_start=eager)
        owners.tasks.append(created)
        if eager:
            assert created.done()

    async def cleanup() -> None:
        assert _marker.get() == "explicit"
        if nested:
            create(leaf())
        else:
            await leaf()

    def delayed(turns: int) -> None:
        if turns:
            loop.call_soon(delayed, turns - 1)
        else:
            create(cleanup())

    async def owner() -> None:
        try:
            await asyncio.Event().wait()
        finally:
            if owners.timing is Timing.FINAL_TURN:
                loop.call_soon(delayed, 6)
            else:
                create(cleanup())
                await checkpoint()
                await checkpoint()

    if owners.timing is Timing.BEFORE_SCAN:
        from _erlang_impl._lifecycle import begin_managed_shutdown

        begin_managed_shutdown(loop)
        create(cleanup())
        await checkpoint()
        await checkpoint()
        assert all(task.done() for task in owners.tasks)
    else:
        owners.tasks.append(asyncio.create_task(owner()))
        await checkpoint()
    return "prepared"


def assert_successors() -> bool:
    owners = _successors.owners
    assert owners is not None
    assert owners.loop.is_closed()
    assert owners.loop.get_task_factory() is owners.factory, "factory changed"
    assert all(task.done() for task in owners.tasks)
    if owners.factory is not None:
        assert len(owners.received) == len(owners.requested), "factory context count"
        assert all(a is b for a, b in zip(owners.requested, owners.received, strict=True)), (
            "factory context identity"
        )
    if owners.fail:
        assert owners.channel.snapshot() == (1, 1, 1, 1, False, 0)
        assert any(not task.cancelled() and task.exception() is not None for task in owners.tasks)
        owners.channel.abort()
    else:
        assert owners.channel.snapshot() == (0, 0, 1, 1, True, 0), "successor did not close channel"
    return True


@dataclass
class Runaway:
    loop: asyncio.AbstractEventLoop
    channel: Channel
    release: asyncio.Event = field(default_factory=asyncio.Event)
    tasks: list[asyncio.Task[None]] = field(default_factory=list)
    generation: int = 0


@dataclass
class RunawayInspection:
    owners: Runaway | None = None


_runaway = RunawayInspection()


async def setup_runaway(owner: object, fail: bool) -> str:
    owners = Runaway(asyncio.get_running_loop(), Channel.create_bytes(capacity=1, max_bytes=1))
    _runaway.owners = owners
    owners.channel.send_bytes_nowait(b"x")

    async def failed() -> None:
        raise ValueError("sensitive cleanup payload")

    async def cleanup() -> None:
        owners.generation += 1
        try:
            await asyncio.Event().wait()
        finally:
            if fail and owners.generation == 1:
                owners.tasks.append(asyncio.create_task(failed()))
            if owners.generation < 32:
                owners.tasks.append(asyncio.create_task(cleanup()))
            else:
                erlang.send(owner, "runaway-gated")
                await owners.release.wait()
                owners.channel.abort()

    owners.tasks.append(asyncio.create_task(cleanup()))
    await checkpoint()
    return "prepared"


async def assert_runaway_retained() -> bool:
    owners = _runaway.owners
    assert owners is not None
    assert owners.generation == 32
    assert not owners.loop.is_closed()
    assert not owners.tasks[-1].done()
    assert owners.tasks[-1].cancelling() == 1
    assert owners.channel.snapshot() == (1, 1, 1, 1, False, 0)
    return True


async def release_runaway() -> str:
    owners = _runaway.owners
    assert owners is not None
    owners.release.set()
    return "released"


def assert_runaway_done() -> bool:
    owners = _runaway.owners
    assert owners is not None
    assert owners.loop.is_closed()
    assert all(task.done() for task in owners.tasks)
    assert owners.channel.snapshot() == (0, 0, 1, 1, True, 0)
    return True

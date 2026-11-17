import asyncio
import os
import threading
import time
from contextvars import Context
from dataclasses import dataclass, field
from functools import partial
from weakref import ref

import erlang
from _erlang_impl._actor_data import _ActorTasks, _task_owner, _worker_loop, wait_worker
from erlang.actors import DataActorGroup


class BackgroundActor:
    def __init__(self) -> None:
        self.finished = threading.Event()

    async def finish(self) -> None:
        await asyncio.sleep(0.01)
        self.finished.set()

    async def dispatch(self, payload: bytes) -> bytes:
        if payload == b"start":
            pending = asyncio.create_task(self.finish())
            del pending
            return b"ok"
        return b"yes" if self.finished.is_set() else b"no"


async def check_progress() -> tuple[bool, bool]:
    finished = threading.Event()

    def factory() -> BackgroundActor:
        actor = BackgroundActor()
        actor.finished = finished
        return actor

    async with DataActorGroup(max_children=1) as group:
        actor = await group.spawn("background", factory)
        await actor.call(b"start")
        idle = await asyncio.to_thread(finished.wait, 5)
        return idle, await actor.call(b"read") == b"yes"


def background_progress() -> tuple[bool, bool]:
    return asyncio.run(check_progress())


class Resource:
    pass


@dataclass
class TaskChecks:
    cancelled: list[threading.Event] = field(default_factory=list)
    released: threading.Event = field(default_factory=threading.Event)
    state: object | None = None
    owners: list[_ActorTasks] = field(default_factory=list)


class PendingActor:
    def __init__(self, checks: TaskChecks) -> None:
        self.checks = checks
        self.resource = Resource()
        self.resource_ref = ref(self.resource, lambda _: checks.released.set())

    async def pending(
        self, cancelled: threading.Event, ready: asyncio.Event, descendant: bool = False
    ) -> None:
        try:
            if not descendant:
                child_ready = asyncio.Event()
                child_cancelled = threading.Event()
                self.checks.cancelled.append(child_cancelled)
                child = asyncio.create_task(
                    self.pending(child_cancelled, child_ready, True), context=Context()
                )
                del child
                await child_ready.wait()
            ready.set()
            await asyncio.Event().wait()
        finally:
            await asyncio.sleep(0)
            assert self.resource_ref() is self.resource
            if self.checks.state is not None:
                assert erlang._actor_unwrap(self.checks.state) is self
            cancelled.set()

    async def dispatch(self, payload: bytes) -> bytes:
        owner = _task_owner.get()
        assert owner is not None
        self.checks.owners.append(owner)
        cancelled = threading.Event()
        self.checks.cancelled.append(cancelled)
        ready = asyncio.Event()
        pending = asyncio.create_task(self.pending(cancelled, ready))
        del pending
        await ready.wait()
        return str(threading.get_native_id()).encode()


async def check_cleanup() -> None:
    for mode in ("kill", "close", "fallback", "blocked"):
        checks = TaskChecks()
        async with DataActorGroup(max_children=1) as group:
            actor = await group.spawn(
                "pending", partial(PendingActor, checks), restart="temporary"
            )
            checks.state = await erlang.async_call("worker_task_object", actor.pid)
            first = await actor.call(b"start")
            if mode == "fallback":
                holder = await erlang.async_call("worker_task_hold", actor.pid)
                try:
                    second = await actor.call(b"start")
                    assert first != second
                    await group.close()
                finally:
                    await erlang.async_call("worker_task_release", holder)
            elif mode == "blocked":
                block_started.clear()
                block_release.clear()
                holder = await erlang.async_call("worker_task_block", actor.pid)
                try:
                    assert await asyncio.to_thread(block_started.wait, 5)
                    async with asyncio.TaskGroup() as pending:
                        pending.create_task(actor.crash())
                        await asyncio.to_thread(wait_closing, checks.owners[0])
                        assert not checks.released.is_set()
                        assert not any(event.is_set() for event in checks.cancelled)
                        block_release.set()
                finally:
                    block_release.set()
                    await erlang.async_call("worker_task_release", holder)
            else:
                holders = await erlang.async_call("worker_task_hold_all")
                try:
                    if mode == "kill":
                        await actor.crash()
                    else:
                        await group.close()
                finally:
                    await erlang.async_call("worker_task_release_all", holders)
            assert all(event.is_set() for event in checks.cancelled)
            assert checks.released.is_set()
        assert all(owner.sealed and not owner.tasks for owner in checks.owners)
    for _ in range(4):
        checks = TaskChecks()
        async with DataActorGroup(max_children=16) as group:
            actors = [
                await group.spawn(str(index), partial(PendingActor, checks))
                for index in range(16)
            ]
            async with asyncio.TaskGroup() as calls:
                for actor in actors:
                    calls.create_task(actor.call(b"start"))
        assert len(checks.cancelled) == 32
        assert all(event.is_set() for event in checks.cancelled)
        assert all(owner.sealed and not owner.tasks for owner in checks.owners)

    shared_checks = TaskChecks()
    shared = PendingActor(shared_checks)
    async with DataActorGroup(max_children=2) as group:
        first = await group.spawn("first", lambda: shared, restart="temporary")
        second = await group.spawn("second", lambda: shared, restart="temporary")
        await first.call(b"start")
        await second.call(b"start")
        assert shared_checks.owners[0] is not shared_checks.owners[1]
        await first.crash()
        assert all(event.is_set() for event in shared_checks.cancelled[:2])
        assert not any(event.is_set() for event in shared_checks.cancelled[2:])
        await second.call(b"start")
    assert all(event.is_set() for event in shared_checks.cancelled)
    assert all(owner.sealed and not owner.tasks for owner in shared_checks.owners)


def background_cleanup() -> None:
    asyncio.run(check_cleanup())


block_started = threading.Event()
block_release = threading.Event()


def blocking_request() -> None:
    block_started.set()
    assert block_release.wait(20)


def reset_block() -> None:
    block_started.clear()
    block_release.clear()


def wait_block_started() -> None:
    assert block_started.wait(5)


def release_block() -> None:
    block_release.set()


def wait_closing(owner: _ActorTasks) -> None:
    while True:
        with owner.lock:
            if owner.sealed:
                return
        time.sleep(0.001)


def queued_wakeups() -> None:
    read, write = os.pipe()
    os.set_blocking(read, False)
    os.set_blocking(write, False)
    try:
        os.write(write, b"x")
        wait_worker(read)
        writes = 0
        try:
            while True:
                os.write(write, b"x" * 4096)
                writes += 1
        except BlockingIOError:
            pass
        assert writes > 0
        wait_worker(read)
        try:
            os.read(read, 1)
        except BlockingIOError:
            pass
        else:
            raise AssertionError("Wakeup pipe was not drained")
        assert _worker_loop.loop is not None
    finally:
        os.close(read)
        os.close(write)


shutdown_finished = threading.Event()
shutdown_tasks: set[asyncio.Task[None]] = set()


async def shutdown_pending(ready: asyncio.Event) -> None:
    try:
        ready.set()
        await asyncio.Event().wait()
    finally:
        await asyncio.sleep(0)
        shutdown_finished.set()


async def arm_shutdown() -> None:
    shutdown_finished.clear()
    ready = asyncio.Event()
    task = asyncio.create_task(shutdown_pending(ready))
    shutdown_tasks.add(task)
    task.add_done_callback(shutdown_tasks.discard)
    await ready.wait()


def prepare_shutdown() -> None:
    _worker_loop.get().run_until_complete(arm_shutdown())


def check_shutdown() -> None:
    assert shutdown_finished.is_set()
    assert not shutdown_tasks

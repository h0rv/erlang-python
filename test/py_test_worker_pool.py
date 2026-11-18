import asyncio
import sys
import threading
import time
from contextvars import ContextVar
from functools import partial

import erlang
from _erlang_impl._actor_data import _worker_loop
from erlang.actors import DataActorGroup


def cpu_work(iterations: int) -> int:
    value = 0
    for number in range(iterations):
        value += number ^ 17
    return value


def blocking_sleep() -> None:
    time.sleep(0.2)


class Worker:
    def __init__(self, barrier: threading.Barrier | None = None) -> None:
        self.barrier = barrier

    async def dispatch(self, payload: bytes) -> bytes:
        if self.barrier is not None:
            self.barrier.wait()
        if payload == b"sleep":
            blocking_sleep()
        elif payload == b"callbacks":
            for _ in range(50):
                await erlang.async_call("worker_pool_echo")
        else:
            cpu_work(int(payload))
        if self.barrier is not None:
            return str(threading.get_native_id()).encode()
        return b"ok"


async def concurrent_calls(
    count: int, payload: bytes, *, overlap: bool = False
) -> float:
    loop = asyncio.get_running_loop()
    loop.add_reader(erlang._get_async_callback_fd(), erlang._async_callback_reader)
    async with DataActorGroup(max_children=count) as group:
        barrier = threading.Barrier(count, timeout=10) if overlap else None
        actors = [
            await group.spawn(str(index), partial(Worker, barrier))
            for index in range(count)
        ]
        start = time.perf_counter()
        async with asyncio.TaskGroup() as tasks:
            pending = [tasks.create_task(actor.call(payload)) for actor in actors]
        elapsed = time.perf_counter() - start
        if overlap:
            assert len({task.result() for task in pending}) == count
        else:
            assert all(task.result() == b"ok" for task in pending)
        return elapsed


def sleeping() -> None:
    asyncio.run(concurrent_calls(16, b"sleep", overlap=True))


def callbacks() -> float:
    return asyncio.run(concurrent_calls(8, b"callbacks"))


def cpu_parallel_supported() -> bool:
    return sys.version_info >= (3, 14) and not sys._is_gil_enabled()


def cpu_parallel() -> None:
    assert not sys._is_gil_enabled()
    asyncio.run(concurrent_calls(8, b"200000", overlap=True))


class _ThreadState(threading.local):
    def __init__(self) -> None:
        self.calls = 0


_thread_state = _ThreadState()

_call_state = ContextVar("pooled_call_state", default=b"empty")


class IsolatedWorker:
    def __init__(self) -> None:
        self.identity: tuple[int, int] | None = None

    async def dispatch(self, payload: bytes) -> bytes:
        identity = (threading.get_native_id(), id(asyncio.get_running_loop()))
        if self.identity is None:
            self.identity = identity
        assert self.identity == identity
        assert _call_state.get() == b"empty"
        assert sys.exception() is None
        _call_state.set(payload)
        await asyncio.sleep(0)
        assert _call_state.get() == payload
        if payload == b"error":
            raise ValueError("expected pooled actor failure")
        return payload


async def isolated_calls() -> None:
    async with DataActorGroup(max_children=1) as group:
        actor = await group.spawn("isolated", IsolatedWorker)
        assert await actor.call(b"first") == b"first"
        assert await actor.call(b"second") == b"second"
        try:
            await actor.call(b"error")
        except ValueError:
            pass
        else:
            raise AssertionError("Actor error was not propagated")
        assert await actor.call(b"recovered") == b"recovered"


def isolated_state() -> None:
    asyncio.run(isolated_calls())


def loop_identity() -> tuple[int, int]:
    _thread_state.calls += 1
    return id(_worker_loop.get()), _thread_state.calls


class SnapshotCounter:
    def __init__(self, directory: str, token: bytes) -> None:
        self.directory = directory
        self.token = token
        self.version = 0
        self.value = b"0"
        self.loaded = False

    async def dispatch(self, payload: bytes) -> bytes:
        if not self.loaded:
            assert await erlang.async_call("_actor_state_open", self.directory) == "ok"
            snapshot = await erlang.async_call("_actor_state_read", b"pooled-counter")
            match snapshot:
                case "missing":
                    pass
                case ("ok", int(version), bytes(value)):
                    self.version, self.value = version, value
                case _:
                    raise RuntimeError("Invalid snapshot", snapshot)
            self.loaded = True
        if payload == b"read":
            return self.value
        result = await erlang.async_call(
            "_actor_state_write", b"pooled-counter", self.version, payload, self.token
        )
        assert result == ("ok", self.version + 1)
        self.version += 1
        self.value = payload
        return str(self.version).encode()


async def persistent_round_trip(directory: str) -> bool:
    assert await erlang.async_call("_actor_state_open", directory) == "ok"
    result = await erlang.async_call(
        "_actor_state_claim", b"pooled-counter", b"pooled-counter-claim"
    )
    match result:
        case ("ok", bytes(token)):
            pass
        case _:
            raise RuntimeError("Invalid ownership claim", result)
    try:
        return await owned_round_trip(directory, token)
    finally:
        assert await erlang.async_call("_actor_state_release", token) == "ok"


async def owned_round_trip(directory: str, token: bytes) -> bool:
    async with DataActorGroup(max_children=1) as group:
        actor = await group.spawn("counter", lambda: SnapshotCounter(directory, token))
        async with asyncio.TaskGroup() as calls:
            pending = [
                calls.create_task(actor.call(value)) for value in (b"1", b"2", b"3")
            ]
        assert sorted(call.result() for call in pending) == [b"1", b"2", b"3"]
        saved = await actor.call(b"read")
        await actor.crash()
        actor = await actor.rejoin()
        assert await actor.call(b"read") == saved
        assert await actor.call(b"4") == b"4"
        assert await erlang.async_call(
            "_actor_state_write", b"pooled-counter", 0, b"stale", token
        ) == ("error", ("version_conflict", 0, 4))
    async with DataActorGroup(max_children=1) as group:
        actor = await group.spawn("counter", lambda: SnapshotCounter(directory, token))
        assert await actor.call(b"read") == b"4"
    return True


def persistent_state(directory: str) -> bool:
    return asyncio.run(persistent_round_trip(directory))

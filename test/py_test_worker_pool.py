import asyncio
import sys
import threading
import time

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
    async def dispatch(self, payload: bytes) -> bytes:
        if payload == b"sleep":
            blocking_sleep()
        elif payload == b"callbacks":
            for _ in range(50):
                await erlang.async_call("worker_pool_echo")
        else:
            cpu_work(int(payload))
        return b"ok"


async def concurrent_calls(count: int, payload: bytes) -> float:
    loop = asyncio.get_running_loop()
    loop.add_reader(erlang._get_async_callback_fd(), erlang._async_callback_reader)
    async with DataActorGroup(max_children=count) as group:
        actors = [await group.spawn(str(index), Worker) for index in range(count)]
        start = time.perf_counter()
        async with asyncio.TaskGroup() as tasks:
            pending = [tasks.create_task(actor.call(payload)) for actor in actors]
        elapsed = time.perf_counter() - start
        assert all(task.result() == b"ok" for task in pending)
        return elapsed


def sleeping() -> float:
    return asyncio.run(concurrent_calls(16, b"sleep"))


def callbacks() -> float:
    return asyncio.run(concurrent_calls(8, b"callbacks"))


def cpu_parallel_supported() -> bool:
    return sys.version_info >= (3, 14) and not sys._is_gil_enabled()


def cpu_parallel() -> tuple[float, float]:
    assert not sys._is_gil_enabled()
    start = time.perf_counter()
    cpu_work(1_000_000)
    iterations = int(1_000_000 * 0.3 / (time.perf_counter() - start))
    payload = str(iterations).encode()
    single = asyncio.run(concurrent_calls(1, payload))
    parallel = asyncio.run(concurrent_calls(8, payload))
    return single, parallel


class _ThreadState(threading.local):
    def __init__(self) -> None:
        self.calls = 0


_thread_state = _ThreadState()


def loop_identity() -> tuple[int, int]:
    _thread_state.calls += 1
    return id(_worker_loop.get()), _thread_state.calls

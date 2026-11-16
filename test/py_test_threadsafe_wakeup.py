import asyncio
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import py_event_loop as native_loop
from _erlang_impl._loop import ErlangEventLoop


def delayed_value() -> int:
    # Delay only the producing thread, never schedule a loop heartbeat.
    time.sleep(0.05)
    return 42


async def threadsafe_result() -> int:
    loop = asyncio.get_running_loop()
    result: asyncio.Future[int] = loop.create_future()

    def complete() -> None:
        loop.call_soon_threadsafe(result.set_result, delayed_value())

    thread = threading.Thread(target=complete)
    thread.start()
    try:
        return await result
    finally:
        thread.join()


async def executor_result() -> int:
    loop = asyncio.get_running_loop()
    total = 0
    with ThreadPoolExecutor(max_workers=1) as executor:
        for _ in range(5):
            total += await loop.run_in_executor(executor, delayed_value)
    return total


async def to_thread_result() -> int:
    return await asyncio.to_thread(delayed_value)


async def burst_result() -> int:
    loop = asyncio.get_running_loop()
    result: asyncio.Future[int] = loop.create_future()
    count = 0
    producers = 4
    per_producer = 500

    def record() -> None:
        nonlocal count
        count += 1
        if count == producers * per_producer:
            result.set_result(count)

    def produce() -> None:
        time.sleep(0.05)
        for _ in range(per_producer):
            loop.call_soon_threadsafe(record)

    threads = [threading.Thread(target=produce) for _ in range(producers)]
    for thread in threads:
        thread.start()
    try:
        return await result
    finally:
        for thread in threads:
            thread.join()


async def ready_chain_result() -> int:
    loop = asyncio.get_running_loop()
    result: asyncio.Future[int] = loop.create_future()
    count = 0

    def step() -> None:
        nonlocal count
        count += 1
        if count == 350:
            result.set_result(count)
        else:
            loop.call_soon(step)

    # One callback per _run_once, so this must cross the native 100-pass budget.
    loop.call_soon(step)
    return await result


def independent_loop_result() -> int:
    loop = ErlangEventLoop(native_loop._loop_new())
    try:
        return loop.run_until_complete(threadsafe_result())
    finally:
        loop.close()


def shutdown_wakeup_result() -> bool:
    capsule = native_loop._loop_new()
    native_loop._loop_destroy(capsule)

    def late_wakeups() -> None:
        for _ in range(1000):
            native_loop._wakeup_for(capsule)

    with ThreadPoolExecutor(max_workers=1) as executor:
        executor.submit(late_wakeups).result()
    return True

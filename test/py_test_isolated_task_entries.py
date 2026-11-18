import asyncio
import os
import signal
import threading
import time

import erlang
from _erlang_impl._tasks import _entries


async def echo(payload: bytes) -> bytes:
    await asyncio.sleep(0)
    return payload


async def must_not_run(payload: bytes) -> bytes:
    raise AssertionError("A sealed entry executed")


async def sealed(token: int) -> bool:
    return _entries[token].sealed


async def asleep(payload: bytes) -> bytes:
    await asyncio.sleep(60)
    return payload


async def failure(payload: bytes) -> bytes:
    raise ValueError("isolated failure\udcff")


async def invalid_result(payload: bytes) -> str:
    return "not bytes"


async def crash(payload: bytes) -> bytes:
    await asyncio.sleep(0.01)
    os.abort()


async def waiting(payload: bytes) -> bytes:
    await erlang.async_call("isolated_task_entered", payload)
    try:
        await asyncio.sleep(60)
    finally:
        await erlang.async_call("isolated_task_finished", payload)
    return payload


async def blocked(payload: bytes) -> bytes:
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1})
    threading.Thread(target=erlang.call, args=("isolated_task_entered", payload)).start()
    time.sleep(30)
    return payload


async def runaway(payload: bytes) -> bytes:
    await erlang.async_call("isolated_task_entered", payload)
    value = 0
    while True:
        value += 1


async def result_then_crash(payload: bytes) -> bytes:
    await erlang.async_call("isolated_task_entered", payload)
    await asyncio.sleep(0.1)
    asyncio.get_running_loop().call_later(0.1, os.abort)
    return payload

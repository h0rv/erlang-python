import asyncio
import gc
import weakref

import erlang
from erlang.tasks import Body, UncertainInflight, dispose, open_group, outcome, shutdown, start


async def retained_exception_lifecycle() -> bool:
    class OriginalError(Exception):
        pass

    for _ in range(3):
        gc.collect()
        await erlang.async_call("task_test_collect")
        await asyncio.sleep(0.01)
    baseline = erlang._actor_retained_object_stats()

    async def scenario() -> weakref.ReferenceType[OriginalError]:
        original = OriginalError("retained task failure")
        weak = weakref.ref(original)

        async def fail(payload: bytes) -> bytes:
            raise original

        group, gate = await open_group(1, 100)
        pid = await start(group, gate, lambda: Body(fail), b"work")
        success, error = await outcome(group, pid)
        assert success is False and error is original
        assert error.__traceback__ is not None
        await shutdown(group, 1000)
        await dispose(group)
        return weak

    for _ in range(3):
        weak = await scenario()
        for _ in range(20):
            gc.collect()
            await erlang.async_call("task_test_collect")
            await asyncio.sleep(0.01)
            if weak() is None and erlang._actor_retained_object_stats() == baseline:
                break
        assert weak() is None
        stats = erlang._actor_retained_object_stats()
        assert stats == baseline, (baseline, stats)
    return True


def unstarted_body() -> Body:
    async def invoke(payload: bytes) -> bytes:
        raise AssertionError("A sealed task executed its callable")

    return Body(invoke)


def enqueue(group: object, gate: object, ticket: object, payload: bytes) -> int:
    async def invoke(value: bytes) -> bytes:
        return value

    erlang._get_async_callback_fd()
    return erlang._send_async_request(
        "_task_start", (group, gate, ticket, payload, erlang._actor_retain(lambda: Body(invoke)))
    )


async def killed(mode: str | bytes) -> bool:
    entered = asyncio.Event()
    release = asyncio.Event()
    ended = asyncio.Event()

    async def invoke(payload: bytes) -> bytes:
        entered.set()
        try:
            await release.wait()
            return payload
        finally:
            ended.set()

    group, gate = await open_group(1, 4096)
    pid = await start(group, gate, lambda: Body(invoke), b"work")
    await entered.wait()
    info = await erlang.async_call("_task_info", group)
    if not isinstance(info, dict):
        raise TypeError("Expected task status")
    contexts = info["contexts"]
    if not isinstance(contexts, list):
        raise TypeError("Expected context PIDs")
    context = contexts[0]
    await erlang.async_call("task_test_capture", group)
    target = {"child": pid, "context": context, "group": group}[
        str(mode, "utf8") if isinstance(mode, bytes) else mode
    ]
    await erlang.async_call("task_test_kill", target)
    if target != group:
        info = await erlang.async_call("_task_info", group)
        if not isinstance(info, dict):
            raise TypeError("Expected task status")
        admission = info["gate"]
        if not isinstance(admission, dict):
            raise TypeError("Expected gate status")
        assert admission["count"] == 1
        assert admission["closed"] is True
    pending = asyncio.create_task(outcome(group, pid))
    success, result = await pending
    assert success is False and isinstance(result, UncertainInflight)
    assert not ended.is_set()
    release.set()
    await ended.wait()
    if target != group:
        await shutdown(group, 1000)
        await dispose(group)
    await erlang.async_call("task_test_down", context)
    await erlang.async_call("task_test_down", pid)
    await erlang.async_call("task_test_reaped")
    return True

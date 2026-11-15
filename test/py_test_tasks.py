import asyncio

import erlang
from erlang.tasks import Body, UncertainInflight, dispose, open_group, outcome, shutdown, start


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

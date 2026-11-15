import asyncio

import erlang
from erlang.tasks import Body, dispose, open_group, outcome, shutdown, start

_held_task: asyncio.Task[object] | None = None


async def hold_callback() -> bool:
    global _held_task
    _held_task = asyncio.create_task(erlang.async_call("composition_held"))
    await asyncio.sleep(0)
    return True


def check_abandoned() -> bool:
    assert _held_task is not None
    assert _held_task.done() and _held_task.cancelled()
    assert _held_task.get_loop().is_closed()
    return True


async def echo_after_close() -> object:
    assert _held_task is not None
    assert asyncio.get_running_loop() is not _held_task.get_loop()
    return await erlang.async_call("composition_echo", 42)


async def owner_identity() -> int:
    return id(asyncio.get_running_loop())


async def nested() -> bool:
    group, gate = await open_group(2, 100)

    async def child(payload: bytes) -> bytes:
        return b"42"

    async def parent(payload: bytes) -> bytes:
        await erlang.async_call("composition_enter", group)
        other = await start(
            group, gate, lambda: Body(child, dedicated_loop=True), b"21"
        )
        success, value = await outcome(group, other)
        assert success and value == b"42"
        return value

    try:
        pid = await start(group, gate, lambda: Body(parent, dedicated_loop=True), b"21")
        async with asyncio.timeout(4):
            success, value = await outcome(group, pid)
        assert success and value == b"42"
        await shutdown(group, 1000)
        info = await erlang.async_call("_task_info", group)
        assert isinstance(info, dict)
        assert info["jobs"] == 0 and not info["contexts"] and not info["children"]
        credits = info["gate"]
        assert isinstance(credits, dict)
        assert credits["count"] == credits["bytes"] == credits["unsettled"] == 0
        return True
    finally:
        await shutdown(group, 1000)
        await dispose(group)

import asyncio
import json
import os

import erlang


async def run(payload: bytes) -> bytes:
    job: object = json.loads(payload)
    match job:
        case {"id": int(identifier), "path": str(path)}:
            pass
        case _:
            raise ValueError("Invalid durable test payload")
    info: object = await erlang.async_call("durable_test_info", payload)
    match info:
        case (str(node), int(attempt)):
            pass
        case _:
            raise ValueError("Invalid durable test metadata")
    await asyncio.sleep(0.2)
    await asyncio.to_thread(append, path, identifier, node, attempt)
    return payload


def append(path: str, identifier: int, node: str, attempt: int) -> None:
    with open(path, "a") as stream:
        stream.write(str(identifier) + " " + node + " " + str(attempt) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


async def echo(payload: bytes) -> bytes:
    return payload


async def fail(payload: bytes) -> bytes:
    raise ValueError("durable test failure")


async def wrong_result(payload: bytes) -> int:
    return 42

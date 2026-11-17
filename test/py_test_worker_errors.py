import asyncio

import erlang
from erlang.actors import DataActorGroup


class ExpectedError(ValueError):
    pass


class ErrorActor:
    def __init__(self, error: BaseException) -> None:
        self.error = error

    async def dispatch(self, payload: bytes) -> bytes:
        if payload == b"error":
            raise self.error
        return payload


async def check_exception() -> None:
    for error in (ExpectedError("original actor error"), asyncio.CancelledError()):
        async with DataActorGroup(max_children=1) as group:
            actor = await group.spawn("error", lambda: ErrorActor(error))
            try:
                await actor.call(b"error")
            except BaseException as caught:
                assert caught is error
            else:
                raise AssertionError("Original actor exception was not raised")
            assert await actor.call(b"") == b""
            assert await actor.call(b"ok") == b"ok"


def exception_identity() -> None:
    erlang.run(check_exception())

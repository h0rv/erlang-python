import asyncio

import erlang


def _result(reply: object) -> object:
    if not isinstance(reply, tuple) or len(reply) != 2:
        raise RuntimeError("Invalid native actor response", reply)
    status, value = reply
    if status == "ok":
        return value
    if status == "error" and isinstance(value, tuple):
        return _result(value)
    if status == "python_error":
        error = erlang._actor_unwrap(value)
        if isinstance(error, BaseException):
            raise error
    raise RuntimeError("Native actor operation failed", reply)


async def _owned_wait[T](pending: asyncio.Task[T]) -> T:
    cancelled: asyncio.CancelledError | None = None
    while not pending.done():
        try:
            await asyncio.shield(pending)
        except asyncio.CancelledError as error:
            cancelled = error
    result = pending.result()
    if cancelled is not None:
        raise cancelled
    return result

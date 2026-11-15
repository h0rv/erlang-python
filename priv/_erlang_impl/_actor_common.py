import asyncio

import erlang


def _result(reply: object) -> object:
    while (
        isinstance(reply, tuple)
        and len(reply) == 2
        and reply[0] == "error"
        and isinstance(reply[1], tuple)
    ):
        reply = reply[1]
    if not isinstance(reply, tuple) or len(reply) != 2:
        raise RuntimeError("Invalid native actor response", reply)
    status, value = reply
    if status == "ok":
        return value
    if status == "python_error":
        error = erlang._actor_unwrap(value)
        if isinstance(error, BaseException):
            # A reusable retained reference must not be kept by this new frame.
            del reply, value
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

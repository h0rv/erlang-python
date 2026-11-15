import asyncio
import gc
import weakref

import erlang
from _erlang_impl._actors import spawn


def pending(name: str) -> asyncio.Future[object]:
    future = asyncio.Future[object]()
    callback_id = erlang._send_async_request(name, ())
    erlang._register_async_future(callback_id, future)
    return future


def install_reader() -> None:
    asyncio.get_running_loop().add_reader(
        erlang._get_async_callback_fd(), erlang._async_callback_reader
    )


async def collect() -> None:
    for _ in range(5):
        await asyncio.sleep(0)
        gc.collect()


async def completed_future() -> bool:
    install_reader()
    future = pending("callback_lifetime_echo")
    reference = weakref.ref(future)
    assert await future == "ok"
    del future
    await collect()
    return reference() is None


class Payload:
    pass


class Echo:
    async def echo(self, payload: Payload) -> Payload:
        return payload

    async def fail(self, failure: ValueError) -> None:
        raise failure


async def actor_result() -> bool:
    install_reader()
    actor = await spawn(Echo, (Echo.echo, Echo.fail), mailbox="unbounded")
    try:
        failure = ValueError("original actor exception")
        try:
            await actor.call(1, Echo.fail, failure)
        except ValueError as error:
            assert error is failure
        else:
            raise AssertionError("Actor exception was not propagated")
        del failure
        payload = Payload()
        reference = weakref.ref(payload)
        result = await actor.call(0, Echo.echo, payload)
        assert result is payload
        del result, payload
    finally:
        await actor.stop()
    del actor
    await erlang.async_call("callback_lifetime_collect")
    await collect()
    return reference() is None


async def saturation() -> tuple[int, int]:
    install_reader()
    accepted = [pending("callback_lifetime_hold") for _ in range(10000)]
    rejected = [pending("callback_lifetime_hold") for _ in range(3)]
    errors = 0
    for future in rejected:
        try:
            await future
        except RuntimeError as error:
            assert str(error) == "async callback queue full"
            errors += 1
        else:
            raise AssertionError("Overflow callback succeeded")
    erlang.call("callback_lifetime_rejected")
    for future in accepted:
        assert await future == "ok"
    assert await erlang.async_call("callback_lifetime_echo") == "ok"
    return len(accepted), errors


async def cancelled_future() -> bool:
    install_reader()
    future = pending("callback_lifetime_cancel")
    released = asyncio.Event()
    reference = weakref.ref(future, lambda _: released.set())
    future.cancel()
    del future
    gc.collect()
    assert reference() is not None
    await erlang.async_call("callback_lifetime_cancel_release")
    async with asyncio.timeout(5):
        await released.wait()
    return reference() is None


def run(case: str) -> object:
    match case:
        case "completed_future":
            return asyncio.run(completed_future())
        case "actor_result":
            return asyncio.run(actor_result())
        case "saturation":
            return asyncio.run(saturation())
        case "cancelled_future":
            return asyncio.run(cancelled_future())
        case _:
            raise ValueError("Unknown callback regression", case)

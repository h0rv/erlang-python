import asyncio
import gc
import weakref

import erlang
from _erlang_impl._actors import spawn


class Payload:
    pass


class Tracked:
    reference: weakref.ReferenceType["Tracked"] | None = None

    def __init__(self) -> None:
        Tracked.reference = weakref.ref(self)

    async def run(self, payload: object = None) -> object:
        loop = asyncio.get_running_loop()
        loop.add_reader(erlang._get_async_callback_fd(), erlang._async_callback_reader)
        await erlang.async_call("actor_lifecycle_gate")
        assert Tracked.reference is not None
        assert Tracked.reference() is self
        return payload


def collected() -> bool:
    gc.collect()
    return Tracked.reference is not None and Tracked.reference() is None


class Base:
    async def inherited(self) -> None:
        pass

    async def overridden(self) -> None:
        pass


class Derived(Base):
    async def overridden(self) -> None:
        pass

    async def fail(self, error: ValueError) -> None:
        raise error


async def cancelled_call() -> bool:
    loop = asyncio.get_running_loop()
    loop.add_reader(erlang._get_async_callback_fd(), erlang._async_callback_reader)
    actor = await spawn(Tracked, (Tracked.run,), mailbox="unbounded")
    payload = Payload()
    reference = weakref.ref(payload)
    pending = asyncio.create_task(actor.call(0, Tracked.run, payload))
    try:
        await erlang.async_call("actor_lifecycle_entered")
        pending.cancel()
        try:
            await pending
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("Caller cancellation was lost")
        del pending, payload
        gc.collect()
        assert reference() is not None
    finally:
        await erlang.async_call("actor_lifecycle_release")
        await actor.stop()
    del actor
    await erlang.async_call("actor_lifecycle_collect")
    for _ in range(5):
        await asyncio.sleep(0)
        gc.collect()
    assert collected()
    return reference() is None


async def registered_methods() -> bool:
    loop = asyncio.get_running_loop()
    loop.add_reader(erlang._get_async_callback_fd(), erlang._async_callback_reader)
    actor = await spawn(
        Derived, (Base.inherited, Derived.overridden, Derived.fail), mailbox="unbounded"
    )
    try:
        assert await actor.call(0, Base.inherited) is None
        assert await actor.call(1, Derived.overridden) is None
        error = ValueError("original exception")
        try:
            await actor.call(2, Derived.fail, error)
        except ValueError as caught:
            assert caught is error
        else:
            raise AssertionError("Actor swallowed exception")
        try:
            await actor.call(0, Derived.overridden)
        except ValueError:
            pass
        else:
            raise AssertionError("Mismatched method identity accepted")
    finally:
        await actor.stop()
    synchronous = type("Synchronous", (Base,), {"overridden": lambda self: None})
    for factory, method in (
        (Derived, Base.overridden),
        (synchronous, Base.overridden),
        (Derived, Derived().inherited),
    ):
        try:
            await spawn(factory, (method,), mailbox="unbounded")
        except ValueError:
            pass
        else:
            raise AssertionError("Nonmember method accepted")
    return True


def registration() -> bool:
    return asyncio.run(registered_methods())


def cancellation() -> bool:
    return asyncio.run(cancelled_call())

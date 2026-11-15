import asyncio
import inspect
from collections.abc import Awaitable, Callable
from types import FunctionType
from typing import Literal

import erlang

from ._actor_common import _owned_wait, _result
from ._actor_data import ActorAdmissionClosed as ActorAdmissionClosed
from ._actor_data import ActorGenerationChanged as ActorGenerationChanged
from ._actor_data import ActorOverloaded as ActorOverloaded
from ._actor_data import DataActorGroup as DataActorGroup
from ._actor_data import DataActorRef as DataActorRef
from ._actor_data import DataDispatcher as DataDispatcher
from ._actor_data import DataTicket as DataTicket


def _validate_method(state: object, method: object) -> None:
    if type(method) is not FunctionType or not inspect.iscoroutinefunction(method):
        raise ValueError("Not an async actor member")
    members: dict[str, object] = {}
    for base in reversed(type(state).__mro__):
        members.update(vars(base))
    if not any(member is method for member in members.values()):
        raise ValueError("Not an async actor member")


async def _outcome(awaitable: Awaitable[object]) -> tuple[bool, object]:
    try:
        return True, await awaitable
    except BaseException as error:
        return False, error


class OwnedActor:
    def __init__(self, pid: object, methods: tuple[object, ...]) -> None:
        self._pid = pid
        self._methods = methods
        self._stopped = False
        self._stopping: asyncio.Task[None] | None = None

    async def call(
        self,
        index: int,
        method: object,
        /,
        *args: object,
        **kwargs: object,
    ) -> object:
        if self._stopped or self._stopping is not None:
            raise RuntimeError("Actor is stopped")
        if erlang._actor_unwrap(self._methods[index]) is not method:
            raise ValueError("The method does not match its native registration")
        reply = await erlang.async_call(
            "_actor_call",
            self._pid,
            self._methods[index],
            erlang._actor_retain(args),
            erlang._actor_retain(kwargs),
        )
        return erlang._actor_unwrap(_result(reply))

    async def _stop(self) -> None:
        await erlang.async_call("_actor_stop", self._pid)
        self._stopped = True
        self._methods = ()

    async def stop(self) -> None:
        if self._stopping is None:
            self._stopping = asyncio.create_task(self._stop())
        await _owned_wait(self._stopping)


async def spawn(
    factory: Callable[[], object],
    methods: tuple[Callable[..., Awaitable[object]], ...],
    *,
    mailbox: Literal["unbounded"],
) -> OwnedActor:
    retained = tuple(erlang._actor_retain(method) for method in methods)
    pending = asyncio.create_task(
        erlang.async_call(
            "_actor_spawn",
            erlang._actor_retain(factory),
            list(retained),
            mailbox,
        )
    )
    try:
        pid = _result(await _owned_wait(pending))
    except asyncio.CancelledError:
        pid = _result(pending.result())
        actor = OwnedActor(pid, retained)
        await actor.stop()
        raise
    return OwnedActor(pid, retained)

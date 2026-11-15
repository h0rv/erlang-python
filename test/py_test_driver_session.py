import asyncio
import threading
from collections.abc import Generator
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass, field
from unittest.mock import patch

import py_event_loop
from _erlang_impl._loop import ErlangEventLoop


@dataclass
class Probe:
    owner: ErlangEventLoop
    stack: ExitStack = field(default_factory=ExitStack)
    token: object | None = None


_probe: Probe | None = None


def install() -> bool:
    global _probe
    owner = py_event_loop._get_loop_ref()
    assert owner is not None
    probe = Probe(owner)
    _probe = probe
    barrier = threading.Barrier(2, timeout=3)
    original = ErlangEventLoop._driver_session

    @contextmanager
    def scheduled(
        loop: ErlangEventLoop, *, allow_current: bool = False
    ) -> Generator[None]:
        if loop is owner and not allow_current:
            barrier.wait()
        with original(loop, allow_current=allow_current):
            yield

    probe.stack.enter_context(
        patch.object(ErlangEventLoop, "_driver_session", scheduled)
    )
    return True


def inspect() -> bool:
    assert _probe is not None
    owner = _probe.owner
    _probe.stack.close()
    print(
        "DRIVER_SESSION_OWNER",
        {
            "running": owner.is_running(),
            "closed": owner.is_closed(),
            "managed_shutdown_requested": owner._managed_shutdown_requested,
            "identity_unchanged": py_event_loop._get_loop_ref() is owner,
        },
        flush=True,
    )
    assert py_event_loop._get_loop_ref() is owner
    assert owner.is_running() and not owner.is_closed()
    assert not owner._managed_shutdown_requested
    assert owner._shutdown_observer is None
    return True


async def continue_work() -> int:
    import erlang

    assert _probe is not None
    assert asyncio.get_running_loop() is _probe.owner
    from erlang.actors import DataActorGroup
    from py_test_actor_data import Counter
    from py_test_callback_owner import nested

    assert await erlang.async_call("driver_session_echo", 42) == 42
    async with DataActorGroup(max_children=1) as group:
        actor = await group.spawn(
            "resume", lambda: Counter(40), capacity=1, max_bytes=8
        )
        assert await actor.call(b"2") == b"42"
    assert await nested()
    return 42


def claim_without_running() -> bool:
    global _probe
    owner = py_event_loop._get_loop_ref()
    assert owner is not None and not owner.is_running()
    token, acquired = py_event_loop._claim_driver_session(owner._loop_capsule, owner)
    assert acquired
    _probe = Probe(owner, token=token)
    return True


def reject_foreign_close() -> bool:
    assert _probe is not None
    owner = _probe.owner
    readers, writers = owner._readers.copy(), owner._writers.copy()
    factory = owner.get_task_factory()
    try:
        owner.close()
    except RuntimeError:
        pass
    else:
        raise AssertionError("foreign close entered a claimed driver session")
    assert not owner.is_closed() and not owner.is_running()
    assert not owner._managed_shutdown_requested
    assert owner._readers == readers and owner._writers == writers
    assert owner.get_task_factory() is factory
    return True


def release_without_running() -> bool:
    assert _probe is not None and _probe.token is not None
    owner = _probe.owner
    py_event_loop._release_driver_session(owner._loop_capsule, owner, _probe.token)
    _probe.token = None
    return True


def startup_failure() -> bool:
    import _erlang_impl

    owner = py_event_loop._get_loop_ref()
    assert owner is not None and not owner.is_running()
    factory = owner.get_task_factory()
    readers = owner._readers.copy()
    writers = owner._writers.copy()

    def fail(loop: ErlangEventLoop) -> None:
        raise RuntimeError("scheduled startup failure")

    with patch.object(ErlangEventLoop, "run_forever", fail):
        try:
            _erlang_impl._run_loop_forever()
        except RuntimeError as error:
            assert str(error) == "scheduled startup failure"
        else:
            raise AssertionError("startup should fail")
    assert py_event_loop._get_loop_ref() is owner
    assert not owner.is_running() and not owner.is_closed()
    assert not owner._managed_shutdown_requested
    assert owner._shutdown_observer is None
    assert owner.get_task_factory() is factory
    assert owner._readers == readers and owner._writers == writers
    # The failed driver's claim has gone. Stale release cannot remove its successor.
    capsule = owner._loop_capsule
    stale, acquired = py_event_loop._claim_driver_session(capsule, owner)
    assert acquired
    py_event_loop._release_driver_session(capsule, owner, stale)
    current, acquired = py_event_loop._claim_driver_session(capsule, owner)
    assert acquired and current is not stale
    try:
        py_event_loop._release_driver_session(capsule, owner, stale)
    except RuntimeError:
        pass
    else:
        raise AssertionError("stale session released its successor")
    py_event_loop._release_driver_session(capsule, owner, current)
    return True

import asyncio
import inspect
import math
from collections.abc import Callable, Coroutine
from importlib import import_module
from typing import Literal

from _erlang_impl._loop import ErlangEventLoop

type ServiceState = Literal["running", "completed", "cancelled", "failed"]


class ServiceBusyError(RuntimeError):
    pass


def _timeout(seconds: float) -> None:
    if not math.isfinite(seconds) or seconds < 0:
        raise ValueError("timeout must be finite and nonnegative")


class ServiceRef:
    """Own one task on the current native worker loop, not a worker context.

    Keep this reference until completion or acknowledged stop. Wait timeouts
    and cancellation of a waiter do not cancel the service. Stop requests
    cancellation once and waits for cleanup, but cannot forcibly kill Python.
    A stop timeout leaves the task owned and running until it really finishes.
    """

    def __init__(self, task: asyncio.Task[None]) -> None:
        self._task = task
        self._stop_requested = False
        task.add_done_callback(self._observe)

    @staticmethod
    def _observe(task: asyncio.Task[None]) -> None:
        if not task.cancelled():
            task.exception()

    def _check_loop(self) -> None:
        if asyncio.get_running_loop() is not self._task.get_loop():
            raise RuntimeError("service references are local to their worker loop")

    @property
    def state(self) -> ServiceState:
        self._check_loop()
        if not self._task.done():
            return "running"
        if self._task.cancelled():
            return "cancelled"
        if self._task.exception() is not None:
            return "failed"
        return "completed"

    async def wait(self, *, timeout: float | None = None) -> None:  # noqa: ASYNC109
        """Observe the original failure, cancellation, or successful completion.

        Timeout only bounds this wait. The terminal result can be read again.
        """
        self._check_loop()
        if timeout is not None:
            _timeout(timeout)
        done, _ = await asyncio.wait((self._task,), timeout=timeout)
        if not done:
            raise TimeoutError("service wait timed out; service was not cancelled")
        self._task.result()

    async def stop(self, *, timeout: float = 5.0) -> None:  # noqa: ASYNC109
        """Request cancellation and acknowledge only after task cleanup finishes.

        Raises TimeoutError if still live, or the original task/cleanup failure.
        A returned None acknowledges completion, not just a cancellation request.
        No second cancellation is injected into an in-progress finally block.
        """
        self._check_loop()
        _timeout(timeout)
        if asyncio.current_task() is self._task:
            raise RuntimeError("a service cannot stop itself")
        if not self._stop_requested and not self._task.done():
            self._stop_requested = True
            self._task.cancel()
        done, _ = await asyncio.wait((self._task,), timeout=timeout)
        if not done:
            raise TimeoutError("service stop timed out; cleanup is not acknowledged")
        if not self._task.cancelled():
            self._task.result()


class ServiceSlot:
    """One admitted service, with no waiting queue or implicit worker spawning.

    Start must run inside an existing ErlangEventLoop, for example an entry
    point submitted with py_context:submit. A live task occupies the slot even
    after a stop timeout. Pass capacity=1 explicitly. A finished task permits
    an explicit new start; there are no automatic restarts or retries.
    Applications must bound slot count.
    """

    def __init__(self, *, capacity: Literal[1]) -> None:
        if capacity != 1:
            raise ValueError("a service slot supports exactly one live task")
        self._ref: ServiceRef | None = None
        self._loop: asyncio.AbstractEventLoop | None = None

    def start[**P](
        self, fn: Callable[P, Coroutine[object, object, None]], *args: P.args, **kwargs: P.kwargs
    ) -> ServiceRef:
        """Start an importable module-level async function with checked arguments.

        Lambdas, closures, bound methods, and callable objects are unsupported.
        This local API passes Python arguments directly, without serialization.
        """
        loop = asyncio.get_running_loop()
        if not isinstance(loop, ErlangEventLoop):
            raise RuntimeError("services require a running ErlangEventLoop")
        if self._loop is not None and self._loop is not loop:
            raise RuntimeError("service slots are local to their worker loop")
        if self._ref is not None and self._ref.state == "running":
            raise ServiceBusyError("service slot is busy")
        if not inspect.isfunction(fn) or not inspect.iscoroutinefunction(fn):
            raise TypeError("service entry point must be an async module-level function")
        if fn.__name__ != fn.__qualname__ or fn.__module__ == "__main__":
            raise ValueError("service entry point must be importable, not a closure or lambda")
        module = import_module(fn.__module__)
        if vars(module).get(fn.__name__) is not fn:
            raise ValueError("service entry point must be exported by its module")
        self._loop = loop
        ref = ServiceRef(asyncio.create_task(fn(*args, **kwargs)))
        self._ref = ref
        return ref

    async def stop(self, *, timeout: float = 5.0) -> None:  # noqa: ASYNC109
        """Stop the current service, if any; preserve ownership on timeout."""
        _timeout(timeout)
        if self._ref is not None:
            await self._ref.stop(timeout=timeout)

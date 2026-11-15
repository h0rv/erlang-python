import asyncio
from contextvars import Context
from weakref import WeakSet


class ShutdownObserver:
    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.failed = False
        self._live: set[asyncio.Future[object]] = set()
        self._seen: WeakSet[asyncio.Future[object]] = WeakSet()
        self._drivers: WeakSet[asyncio.Future[object]] = WeakSet()
        self._eligible: set[asyncio.Future[object]] = set()
        self._change = asyncio.Future[None](loop=loop)

    def observe(self, future: asyncio.Future[object]) -> None:
        if future.get_loop() is not self.loop or future in self._seen:
            return
        self._seen.add(future)
        if future in self._drivers:
            return
        self._live.add(future)
        if future.done():
            self._finished(future)
        else:
            future.add_done_callback(self._finished, context=Context())
            # Task construction schedules its first step before this marker.
            # Let cleanup enter its try/finally before requesting cancellation.
            self.loop.call_soon(self._started, future, context=Context())

    def _started(self, future: asyncio.Future[object]) -> None:
        if future not in self._live:
            return
        if future.done():
            self._finished(future)
        else:
            self._eligible.add(future)
        self._notify()

    def _notify(self) -> None:
        if not self._change.done():
            self._change.set_result(None)

    def changed(self) -> asyncio.Future[None]:
        if self._change.done():
            self._change = asyncio.Future[None](loop=self.loop)
        return self._change

    def cancellable(self, future: asyncio.Future[object]) -> bool:
        return future in self._eligible

    def _finished(self, future: asyncio.Future[object]) -> None:
        if future not in self._live:
            return
        self._live.remove(future)
        self._eligible.discard(future)
        self._notify()
        if not future.cancelled() and future.exception() is not None:
            # Keep a sticky failure, not application exceptions or tracebacks.
            self.failed = True

    def exclude_driver(self) -> None:
        current = asyncio.current_task(self.loop)
        if current is None:
            raise RuntimeError("Managed shutdown requires a driver task")
        self._drivers.add(current)
        self._live.discard(current)
        self._eligible.discard(current)

    def pending(self) -> set[asyncio.Future[object]]:
        for task in asyncio.all_tasks(self.loop):
            self.observe(task)
        # Observe completion synchronously too: a done callback may not have
        # run yet, and eager tasks can finish before creation returns.
        for future in tuple(self._live):
            if future.done():
                self._finished(future)
        return self._live.copy()

    def errors(self) -> list[BaseException]:
        if self.failed:
            return [RuntimeError("Managed loop cleanup failed")]
        return []


def begin_managed_shutdown(loop: asyncio.AbstractEventLoop) -> ShutdownObserver:
    from _erlang_impl._loop import ErlangEventLoop

    if not isinstance(loop, ErlangEventLoop):
        raise RuntimeError("Managed shutdown requires an ErlangEventLoop")
    observer = loop._shutdown_observer
    if observer is None:
        observer = ShutdownObserver(loop)
        loop._shutdown_observer = observer
        observer.pending()
    return observer


async def _cancel_tasks(loop: asyncio.AbstractEventLoop) -> list[BaseException]:
    observer = begin_managed_shutdown(loop)
    observer.exclude_driver()
    cancelled: WeakSet[asyncio.Future[object]] = WeakSet()
    while True:
        changed = observer.changed()
        pending = observer.pending()
        if not pending:
            await asyncio.sleep(0)
            if not observer.pending():
                return observer.errors()
            continue
        for future in pending:
            if future in cancelled or not observer.cancellable(future):
                continue
            graph = asyncio.capture_call_graph(future, limit=0)
            if graph is None:
                raise RuntimeError("Cannot inspect a managed shutdown task")
            if any(parent.future in pending for parent in graph.awaited_by):
                continue
            if not isinstance(future, asyncio.Task) or not future.cancelling():
                future.cancel()
            cancelled.add(future)
        await asyncio.wait((*pending, changed), return_when=asyncio.FIRST_COMPLETED)


async def shutdown_managed_loop(loop: asyncio.AbstractEventLoop) -> list[BaseException]:
    observer = begin_managed_shutdown(loop)
    observer.exclude_driver()
    await _cancel_tasks(loop)
    try:
        await loop.shutdown_asyncgens()
    except BaseExceptionGroup:
        observer.failed = True
    await _cancel_tasks(loop)
    await loop.shutdown_default_executor()
    observer.pending()
    return observer.errors()

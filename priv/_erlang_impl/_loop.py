# Copyright 2026 Benoit Chesneau
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Erlang-native asyncio event loop implementation.

This module provides the core ErlangEventLoop class that implements
asyncio.AbstractEventLoop using Erlang's scheduler via enif_select
for I/O multiplexing.

Architecture:
- Single event loop per interpreter (no multi-loop complexity)
- Uses enif_select for fd monitoring
- Uses a Python timer heap and deadline-based native waits
- Full GIL release during waits
"""

import asyncio
import contextvars
import heapq
import math
import os
import socket
import sys
import threading
import time
from asyncio import events, futures, tasks
from collections import deque
from collections.abc import AsyncGenerator, Generator
from contextlib import contextmanager
from typing import TYPE_CHECKING, Callable, Never
from weakref import WeakSet

if TYPE_CHECKING:
    from _erlang_impl._lifecycle import ShutdownObserver

from _erlang_impl._fd import (
    FdCallback,
    FdPublication,
    FdPublicationPhase,
    FdRetirement,
    FdRetirementError,
    parse_fd_retirement,
)
from _erlang_impl._mode import detect_mode

__all__ = ['ErlangEventLoop', '_run_and_send']

# Event type constants (match C enum values for fast integer comparison)
EVENT_TYPE_READ = 1
EVENT_TYPE_WRITE = 2
EVENT_TYPE_TIMER = 3

_MAX_TIMER_DELAY = 24 * 60 * 60


class _PooledHandle(events.Handle):
    """Handle recycled through ErlangEventLoop._handle_pool.

    Only fd event dispatch creates these; they never leave the loop, so no
    one can cancel one after it ran and hit its next occupant.
    """
    __slots__ = ('_fd_callback_id',)


class ErlangEventLoop(asyncio.AbstractEventLoop):
    """asyncio event loop backed by Erlang's scheduler.

    This event loop implementation delegates I/O multiplexing to Erlang
    via enif_select, providing:

    - Sub-millisecond latency (vs 10ms polling)
    - Zero CPU usage when idle
    - Full GIL release during waits
    - Native Erlang scheduler integration
    - Subinterpreter and free-threaded Python support

    The loop works by:
    1. add_reader/add_writer register fds with enif_select
    2. call_later adds deadlines to a Python heap
    3. _run_once waits for events (GIL released in C)
    4. Callbacks are dispatched when events occur
    """

    # Use __slots__ for faster attribute access and reduced memory
    __slots__ = (
        '_pel', '_loop_capsule', '_uses_global_capsule', '_owns_capsule',
        '_readers', '_writers',
        '_callbacks_by_cid',  # callback_id -> (callback, args, event_type) for O(1) dispatch
        '_fd_resources',  # logical fd -> owned native poll lease key
        '_fd_retirement_failed', '_closing_sockets', '_fd_publications',
        '_timers', '_scheduled', '_timer_cancelled_count',
        '_timer_ref', '_timer_deadline', '_timer_callback_id',
        '_ready',
        '_handle_pool', '_handle_pool_max', '_running', '_stopping', '_closed',
        '_thread_id', '_clock_resolution', '_exception_handler', '_current_handle',
        '_debug', '_task_factory', '_default_executor',
        '_ready_append', '_ready_popleft',
        '_signal_handlers',
        '_execution_mode',
        '_callback_id',
        '_cached_time',  # uvloop-style time caching to avoid syscalls
        '_wake_pending',  # coalesced wakeup flag for call_soon_threadsafe
        '_asyncgens', '_managed_shutdown_requested', '_shutdown_observer',
    )

    def __init__(self, capsule: object | None = None) -> None:
        """Initialize the Erlang event loop.

        The event loop is backed by Erlang's scheduler via the py_event_loop
        C module. This provides direct access to the event loop without
        going through Erlang callbacks.

        Without ``capsule`` the loop attaches to the interpreter's default
        (global) loop. The event loop pool passes a capsule over one of its
        own loops so timers, fd events and the pending queue stay on that
        loop; such a capsule is owned by Erlang and never destroyed here.
        """
        # Detect execution mode for proper behavior
        self._execution_mode = detect_mode()

        try:
            import py_event_loop as pel
            self._pel = pel

            # Check if initialized
            if not pel._is_initialized():
                raise RuntimeError(
                    "Erlang event loop not initialized. "
                    "Make sure erlang_python application is started."
                )
        except ImportError:
            # Fallback for testing without actual NIF
            self._pel = _MockNifModule()

        # Use the global loop capsule instead of creating a new one.
        # The global loop (created by Erlang) has has_worker=true, which ensures
        # that timers and FD events are dispatched to the worker process.
        # The worker triggers process_ready_tasks which calls _run_once.
        # Without this, Python-created loops would have their own pending queues
        # that never get processed because the worker doesn't know about them.
        self._uses_global_capsule = False
        self._owns_capsule = False
        if capsule is not None:
            self._loop_capsule = capsule
        elif hasattr(self._pel, '_get_global_loop_capsule'):
            try:
                self._loop_capsule = self._pel._get_global_loop_capsule()
                self._uses_global_capsule = True
                # A shared resource stays owned between driver turns.
                if hasattr(self._pel, '_has_loop_ref') and self._pel._has_loop_ref(self._loop_capsule):
                    raise RuntimeError(
                        "An ErlangEventLoop already exists for this native resource. "
                        "Close its owner before constructing another wrapper."
                    )
            except RuntimeError as e:
                # Re-raise our "already exists" error
                if "already exists" in str(e):
                    raise
                # Fall back to creating a new loop if global not available
                self._loop_capsule = self._pel._loop_new()
                self._uses_global_capsule = False
                self._owns_capsule = True
        else:
            self._loop_capsule = self._pel._loop_new()
            self._owns_capsule = True

        # Callback management
        self._readers = {}  # fd -> (callback, args, callback_id)
        self._writers = {}  # fd -> (callback, args, callback_id)
        self._callbacks_by_cid: dict[int, FdCallback] = {}
        self._fd_resources: dict[int, int] = {}
        self._fd_publications: dict[int, FdPublication] = {}
        self._fd_retirement_failed: set[int] = set()
        self._closing_sockets: dict[int, socket.socket] = {}
        self._timers = {}   # callback_id -> handle
        self._scheduled = []
        self._timer_cancelled_count = 0
        self._timer_ref = None
        self._timer_deadline = None
        self._timer_callback_id = None
        self._ready = deque()  # Callbacks ready to run

        # Cache deque methods for hot path
        self._ready_append = self._ready.append
        self._ready_popleft = self._ready.popleft

        # Handle object pool for reduced allocations
        self._handle_pool = []
        self._handle_pool_max = 150

        # Time caching (uvloop-style: avoids time.monotonic() syscalls)
        self._cached_time = time.monotonic()

        # Wakeup coalescing flag
        self._wake_pending = False

        # State
        self._running = False
        self._stopping = False
        self._closed = False
        self._thread_id = None
        self._clock_resolution = 1e-9  # nanoseconds

        # Exception handling
        self._exception_handler = None
        self._current_handle = None

        # Debug mode
        self._debug = False

        # Task factory
        self._task_factory = None

        # Executor
        self._default_executor = None

        # Signal handlers
        self._signal_handlers = {}

        # Callback ID counter
        self._callback_id = 0
        self._asyncgens: WeakSet[AsyncGenerator[object]] = WeakSet()
        self._managed_shutdown_requested = False
        self._shutdown_observer: ShutdownObserver | None = None

        # Publish only fully initialized objects. Native claim rejects capsule
        # aliases on every constructor path, including explicit capsules.
        if hasattr(self._pel, '_set_loop_ref'):
            self._pel._set_loop_ref(self._loop_capsule, self)

    async def _async_call(self, func_name: str, args: tuple[object, ...]) -> object:
        import erlang

        self._check_closed()
        future = self.create_future()
        callback_id, reply = erlang._prepare_native_async_reply(self._loop_capsule, self)

        def completed() -> None:
            if future.done():
                return
            try:
                value = erlang._take_native_async_reply(reply, self)
            except BaseException as error:
                future.set_exception(error)
            else:
                future.set_result(value)

        try:
            # Publish the owning handler before the request can complete on a
            # different Erlang scheduler. No interpreter-wide Future map or
            # callback pipe participates in native loop delivery.
            self._timers[callback_id] = events.Handle(completed, (), self)
            erlang._send_async_request(func_name, args, reply)
            return await future
        finally:
            handle = self._timers.pop(callback_id, None)
            if handle is not None:
                handle.cancel()
            erlang._abandon_native_async_reply(reply)

    async def _unsupported_io(self, *args: object, **kwargs: object) -> Never:
        raise NotImplementedError("This asyncio I/O operation is not supported by ErlangEventLoop")

    # These inherited operations already raise NotImplementedError. Declare that
    # unsupported surface explicitly instead of appearing abstract to type checkers.
    start_tls = _unsupported_io
    sendfile = _unsupported_io
    connect_read_pipe = _unsupported_io
    connect_write_pipe = _unsupported_io
    sock_recvfrom = _unsupported_io
    sock_recvfrom_into = _unsupported_io
    sock_sendto = _unsupported_io

    def _next_id(self):
        """Generate a unique callback ID for this loop."""
        self._callback_id += 1
        return self._callback_id

    # ========================================================================
    # Running and stopping the event loop
    # ========================================================================

    @contextmanager
    def _driver_session(self, *, allow_current: bool = False) -> Generator[None]:
        capsule = self._loop_capsule
        token, acquired = self._pel._claim_driver_session(capsule, self, allow_current)
        try:
            yield
        finally:
            if acquired:
                self._pel._release_driver_session(capsule, self, token)

    def run_forever(self):
        """Run the event loop until stop() is called."""
        with self._driver_session(allow_current=True):
            return self._run_forever_owned()

    def _run_forever_owned(self):
        self._check_closed()
        self._check_running()
        self._set_coroutine_origin_tracking(self._debug)

        self._thread_id = threading.get_ident()
        self._running = True
        # Don't reset _stopping here - honor stop() called before run_forever()

        # Tell the NIF this loop consumes its own events from now on
        set_running = getattr(self._pel, '_set_running_for', None)
        if set_running is not None:
            try:
                set_running(self._loop_capsule, True)
            except Exception:
                set_running = None

        # Register as the running loop
        old_running_loop = events._get_running_loop()
        old_asyncgen_hooks = sys.get_asyncgen_hooks()
        sys.set_asyncgen_hooks(
            firstiter=self._asyncgen_firstiter_hook,
            finalizer=self._asyncgen_finalizer_hook,
        )
        events._set_running_loop(self)
        try:
            while not self._stopping:
                self._run_once()
        finally:
            sys.set_asyncgen_hooks(*old_asyncgen_hooks)
            events._set_running_loop(old_running_loop)
            self._stopping = False
            self._running = False
            if set_running is not None:
                try:
                    set_running(self._loop_capsule, False)
                except Exception:
                    pass
            self._thread_id = None
            self._set_coroutine_origin_tracking(False)

    def run_until_complete(self, future):
        """Run the event loop until a future is done."""
        with self._driver_session(allow_current=True):
            return self._run_until_complete_owned(future)

    def _run_until_complete_owned(self, future):
        self._check_closed()
        self._check_running()

        # Set running loop early so task factories work correctly
        old_running_loop = events._get_running_loop()
        events._set_running_loop(self)
        try:
            new_task = not futures.isfuture(future)
            future = tasks.ensure_future(future, loop=self)

            if new_task:
                future._log_destroy_pending = False

            def _done_callback(f):
                self.stop()

            future.add_done_callback(_done_callback)

            try:
                self.run_forever()
            except Exception:
                if new_task and future.done() and not future.cancelled():
                    future.exception()
                raise
            finally:
                future.remove_done_callback(_done_callback)

            if not future.done():
                raise RuntimeError('Event loop stopped before Future completed.')

            return future.result()
        finally:
            events._set_running_loop(old_running_loop)

    def stop(self):
        """Stop the event loop."""
        self._stopping = True
        try:
            self._pel._wakeup_for(self._loop_capsule)
        except Exception:
            pass

    def is_running(self):
        """Return True if the event loop is running."""
        return self._running

    def is_closed(self):
        """Return True if the event loop is closed."""
        return self._closed

    def close(self):
        """Close the event loop."""
        if self._running:
            raise RuntimeError("Cannot close a running event loop")
        if self._closed:
            return
        if self._pel._has_loop_ref(self._loop_capsule):
            with self._driver_session(allow_current=True):
                self._close_owned()
        else:
            # Explicit native disposal may already have released this wrapper.
            self._close_owned()

    def _close_owned(self):
        # Cancel all timers
        for handle in self._scheduled:
            handle.cancel()
            handle._scheduled = False
        self._scheduled.clear()
        self._timer_cancelled_count = 0
        for handle in self._timers.values():
            handle.cancel()
        if self._timer_ref is not None:
            self._pel._cancel_timer_for(self._loop_capsule, self._timer_ref)
        self._timer_ref = None
        self._timer_deadline = None
        self._timers.clear()

        # Pending publications own keys even when no logical map was published.
        while self._fd_publications:
            publication = next(iter(self._fd_publications.values()))
            self._retire_fd_publication(publication)
        # A failed lease retirement leaves this owner open and retryable.
        for fd, fd_key in list(self._fd_resources.items()):
            self._retire_fd(fd, fd_key)
        self._closed = True

        # Clear signal handlers
        self._signal_handlers.clear()

        # Shutdown default executor - wait=True ensures all executor callbacks
        # complete before loop destruction to prevent use-after-free
        if self._default_executor is not None:
            self._default_executor.shutdown(wait=True)
            self._default_executor = None

        # Clear loop ref to allow creating a new loop later.
        # This is important for the global capsule case where the capsule
        # persists but a new Python loop may be created.
        if self._loop_capsule is not None and hasattr(self._pel, '_clear_loop_ref'):
            self._pel._clear_loop_ref(self._loop_capsule, self, self._owns_capsule)
        self._loop_capsule = None

    def _asyncgen_firstiter_hook(self, generator: AsyncGenerator[object]) -> None:
        self._asyncgens.add(generator)

    def _asyncgen_finalizer_hook(self, generator: AsyncGenerator[object]) -> None:
        self._asyncgens.discard(generator)
        if not self.is_closed():
            self.call_soon_threadsafe(self.create_task, generator.aclose())

    async def shutdown_asyncgens(self) -> None:
        generators = tuple(self._asyncgens)
        self._asyncgens.clear()
        closing = [self.create_task(generator.aclose()) for generator in generators]
        if not closing:
            return
        await asyncio.wait(closing)
        errors = [task.exception() for task in closing if not task.cancelled()]
        failures = [error for error in errors if error is not None]
        if failures:
            raise BaseExceptionGroup("Asynchronous generator cleanup failed", failures)

    async def shutdown_default_executor(self, timeout=None):
        """Shutdown the default executor."""
        if self._default_executor is not None:
            self._default_executor.shutdown(wait=True)
            self._default_executor = None

    # ========================================================================
    # Scheduling callbacks
    # ========================================================================

    def call_soon(self, callback, *args, context=None):
        """Schedule a callback to be called soon.

        Uses handle pooling (uvloop-style) to reduce allocations.
        """
        self._check_closed()
        # A handle handed to the caller must not come from the pool: asyncio
        # code keeps call_soon/call_later handles and cancels them after they
        # ran (asyncio.sleep does), which would cancel whatever callback the
        # recycled handle carries by then. Pooling stays for the fd event
        # handles created in _dispatch, which never leave the loop.
        if context is None:
            context = contextvars.copy_context()
        handle = events.Handle(callback, args, self, context)
        self._ready_append(handle)
        return handle

    def call_soon_threadsafe(self, callback, *args, context=None):
        """Thread-safe version of call_soon.

        Uses coalesced wakeup to reduce wakeup overhead under high call rates.
        """
        handle = self.call_soon(callback, *args, context=context)
        # Coalesced wakeup: only wake if not already pending
        if not self._wake_pending:
            self._wake_pending = True
            try:
                self._pel._wakeup_for(self._loop_capsule)
            except Exception:
                pass
        return handle

    def call_later(self, delay, callback, *args, context=None):
        """Schedule a callback to be called after delay seconds."""
        self._check_closed()
        return self.call_at(self.time() + delay, callback, *args, context=context)

    def call_at(self, when, callback, *args, context=None):
        """Schedule a callback to be called at a specific time."""
        self._check_closed()

        # For zero or past times, run at the next iteration. Return a real
        # TimerHandle (never pooled): callers cancel it after it ran.
        if when <= self.time():
            if context is None:
                context = contextvars.copy_context()
            handle = events.TimerHandle(when, callback, args, self, context)
            self._ready_append(handle)
            return handle

        handle = events.TimerHandle(when, callback, args, self, context)
        heapq.heappush(self._scheduled, handle)
        handle._scheduled = True
        if not self._running:
            self._arm_timer_wakeup()
        return handle

    def time(self):
        """Return the current time according to the event loop's clock.

        When the loop is running, uses cached time (uvloop-style) to avoid
        syscalls. When the loop is not running, returns fresh monotonic time.
        """
        if self._running:
            return self._cached_time
        return time.monotonic()

    def _update_time(self):
        """Update the cached time. Called at the start of each iteration."""
        self._cached_time = time.monotonic()

    # ========================================================================
    # Creating Futures and Tasks
    # ========================================================================

    def create_future(self):
        """Create a Future object attached to this loop."""
        return futures.Future(loop=self)

    def create_task(self, coro, *, name=None, context=None, eager_start=None):
        """Schedule a coroutine to be executed."""
        self._check_closed()
        if self._task_factory is None:
            if sys.version_info >= (3, 12):
                # Native admission retains the historical non-eager default.
                task = tasks.Task(coro, loop=self, name=name, context=context,
                                  eager_start=False if eager_start is None else eager_start)
            elif sys.version_info >= (3, 11):
                task = tasks.Task(coro, loop=self, name=name, context=context)
            elif sys.version_info >= (3, 8):
                task = tasks.Task(coro, loop=self, name=name)
            else:
                task = tasks.Task(coro, loop=self)
                if name is not None:
                    task.set_name(name)
        else:
            if eager_start is not None:
                if context is None:
                    task = self._task_factory(self, coro, eager_start=eager_start)
                else:
                    task = self._task_factory(self, coro, context=context, eager_start=eager_start)
            elif sys.version_info >= (3, 11) and context is not None:
                task = self._task_factory(self, coro, context=context)
            else:
                task = self._task_factory(self, coro)
            if name is not None:
                task.set_name(name)
        if self._shutdown_observer is not None:
            self._shutdown_observer.observe(task)
        return task

    def set_task_factory(self, factory):
        """Set a task factory."""
        self._task_factory = factory

    def get_task_factory(self):
        """Return the task factory."""
        return self._task_factory

    # ========================================================================
    # File descriptor callbacks
    # ========================================================================

    def add_reader(self, fd, callback, *args):
        """Register a reader callback for a file descriptor."""
        self._check_closed()

        self._add_fd_callback(fd, callback, args, reading=True)

    def remove_reader(self, fd):
        """Unregister a reader callback for a file descriptor."""
        return self._remove_fd_callback(fd, reading=True, release=True)

    def add_writer(self, fd, callback, *args):
        """Register a writer callback for a file descriptor."""
        self._check_closed()

        self._add_fd_callback(fd, callback, args, reading=False)

    def remove_writer(self, fd):
        """Unregister a writer callback for a file descriptor."""
        return self._remove_fd_callback(fd, reading=False, release=True)

    def _add_fd_callback(
        self, fd: int, callback: Callable[..., object], args: tuple[object, ...],
        *, reading: bool,
    ) -> None:
        pending = self._fd_publications.get(fd)
        if pending is not None:
            raise FdRetirementError(pending.key)
        key = self._fd_resources.get(fd)
        if key is not None and key in self._fd_retirement_failed:
            raise FdRetirementError(key)
        registrations = self._readers if reading else self._writers
        callback_id = self._pel._new_fd_callback_id()
        publication = FdPublication(
            fd, reading, (callback, args, callback_id), registrations.get(fd),
            shared=key is not None, key=0 if key is None else key,
        )
        # This insertion and the slot allocation precede every native effect.
        # STORE_ATTR into the existing slot needs no fallback allocation.
        self._fd_publications[fd] = publication
        try:
            if not publication.shared:
                if reading:
                    publication.key = self._pel._add_reader_for(
                        self._loop_capsule, fd, callback_id,
                    )
                else:
                    publication.key = self._pel._add_writer_for(
                        self._loop_capsule, fd, callback_id,
                    )
                publication.phase = FdPublicationPhase.NATIVE_OWNED
                self._fd_resources[fd] = publication.key
            self._callbacks_by_cid[callback_id] = FdCallback(
                callback, args, publication.key, fd,
            )
            registrations[fd] = publication.entry
            if publication.shared:
                # Publish all fallible Python records before changing an
                # existing lease. A publication failure cannot stop its writer.
                publication.phase = FdPublicationPhase.UPDATING
                if reading:
                    self._pel._update_fd_read(publication.key, callback_id)
                else:
                    self._pel._update_fd_write(publication.key, callback_id)
            if publication.old_entry is not None:
                self._callbacks_by_cid.pop(publication.old_entry[2], None)
            del self._fd_publications[fd]
        except Exception as error:
            if publication.phase == FdPublicationPhase.UPDATING:
                publication.phase = FdPublicationPhase.UPDATE_FAILED
                # Native update may have taken effect. Keep the shared owner
                # and quarantine callbacks until explicit whole-lease cleanup.
                raise FdRetirementError(publication.key) from error
            publication.phase = FdPublicationPhase.PUBLICATION_FAILED
            if publication.shared:
                self._restore_fd_publication(publication)
                del self._fd_publications[fd]
            else:
                self._retire_fd_publication(publication)
            raise RuntimeError("FD callback publication failed") from error

    def _restore_fd_publication(self, publication: FdPublication) -> None:
        registrations = self._readers if publication.reading else self._writers
        entry = registrations.get(publication.fd)
        if entry is not None and entry[2] == publication.entry[2]:
            if publication.old_entry is None:
                del registrations[publication.fd]
            else:
                registrations[publication.fd] = publication.old_entry
        self._callbacks_by_cid.pop(publication.entry[2], None)

    def _retire_fd_publication(self, publication: FdPublication) -> None:
        try:
            if publication.key != 0:
                parse_fd_retirement(self._pel._release_fd_resource(publication.key))
        except Exception as error:
            # No dict/set insertion here: the loop owned this slot before the
            # native call, including its key, callback and optional socket.
            publication.phase = FdPublicationPhase.ROLLBACK_FAILED
            raise FdRetirementError(publication.key) from error
        publication.phase = FdPublicationPhase.RETIRED
        self._finish_fd_retirement(publication.fd, publication.key)
        registrations = self._readers if publication.reading else self._writers
        entry = registrations.get(publication.fd)
        if entry is not None and entry[2] == publication.entry[2]:
            del registrations[publication.fd]
        self._callbacks_by_cid.pop(publication.entry[2], None)
        if publication.old_entry is not None:
            self._callbacks_by_cid.pop(publication.old_entry[2], None)
        if publication.closing_socket is not None:
            publication.closing_socket.close()
        del self._fd_publications[publication.fd]

    def _retire_fd(self, fd: int, key: int) -> FdRetirement:
        try:
            outcome = parse_fd_retirement(self._pel._release_fd_resource(key))
        except Exception as error:
            self._fd_retirement_failed.add(key)
            raise FdRetirementError(key) from error
        # All three outcomes permit releasing the logical owner. POLL_PENDING
        # means the private duplicate is still owned by ERTS, not closed.
        self._finish_fd_retirement(fd, key)
        return outcome

    def _finish_fd_retirement(self, fd: int, key: int) -> None:
        if self._fd_resources.get(fd) == key:
            del self._fd_resources[fd]
            for registrations in (self._readers, self._writers):
                entry = registrations.pop(fd, None)
                if entry is not None:
                    self._callbacks_by_cid.pop(entry[2], None)
        self._fd_retirement_failed.discard(key)
        closing_socket = self._closing_sockets.pop(key, None)
        if closing_socket is not None:
            closing_socket.close()

    def _remove_fd_callback(self, fd: int, *, reading: bool, release: bool) -> bool:
        registrations = self._readers if reading else self._writers
        others = self._writers if reading else self._readers
        publication = self._fd_publications.get(fd)
        if publication is not None and (
            publication.reading == reading or fd in registrations
        ):
            self._retire_fd_publication(publication)
            return True
        entry = registrations.get(fd)
        if entry is None:
            return False
        key = self._fd_resources[fd]
        if key in self._fd_retirement_failed or (release and fd not in others):
            self._retire_fd(fd, key)
            return True
        try:
            if reading:
                self._pel._clear_fd_read(key)
            else:
                self._pel._clear_fd_write(key)
        except Exception as error:
            self._fd_retirement_failed.add(key)
            raise FdRetirementError(key) from error
        del registrations[fd]
        self._callbacks_by_cid.pop(entry[2], None)
        return True

    def _stop_reading(self, fd: int) -> bool:
        return self._remove_fd_callback(fd, reading=True, release=False)

    def _stop_writing(self, fd: int) -> bool:
        return self._remove_fd_callback(fd, reading=False, release=False)

    def _close_socket(self, sock: socket.socket) -> None:
        """Close the logical socket only after its poll lease was released.

        Failure retains this socket, its mappings and retry key. Retrying
        closes the same owner; no detach or raw-close fallback is allowed.
        """
        fd = sock.fileno()
        if fd < 0:
            return
        publication = self._fd_publications.get(fd)
        if publication is not None:
            publication.closing_socket = sock
            self._retire_fd_publication(publication)
            return
        key = self._fd_resources.get(fd)
        if key is None:
            sock.close()
            return
        self._closing_sockets[key] = sock
        self._retire_fd(fd, key)

    # ========================================================================
    # Socket operations
    # ========================================================================

    async def sock_recv(self, sock, nbytes):
        """Receive data from a socket."""
        fut = self.create_future()

        def _recv():
            if fut.done():
                return
            try:
                data = sock.recv(nbytes)
            except (BlockingIOError, InterruptedError):
                return
            except Exception as error:
                try:
                    self.remove_reader(sock.fileno())
                except FdRetirementError as cleanup_error:
                    fut.set_exception(cleanup_error)
                else:
                    fut.set_exception(error)
                return
            try:
                self.remove_reader(sock.fileno())
            except FdRetirementError as error:
                fut.set_exception(error)
            else:
                fut.set_result(data)

        self.add_reader(sock.fileno(), _recv)
        return await fut

    async def sock_recv_into(self, sock, buf):
        """Receive data from a socket into a buffer."""
        fut = self.create_future()

        def _recv_into():
            if fut.done():
                return
            try:
                nbytes = sock.recv_into(buf)
            except (BlockingIOError, InterruptedError):
                return
            except Exception as error:
                try:
                    self.remove_reader(sock.fileno())
                except FdRetirementError as cleanup_error:
                    fut.set_exception(cleanup_error)
                else:
                    fut.set_exception(error)
                return
            try:
                self.remove_reader(sock.fileno())
            except FdRetirementError as error:
                fut.set_exception(error)
            else:
                fut.set_result(nbytes)

        self.add_reader(sock.fileno(), _recv_into)
        return await fut

    async def sock_sendall(self, sock, data):
        """Send data to a socket."""
        fut = self.create_future()
        data = memoryview(data)
        offset = [0]

        def _send():
            if fut.done():
                return
            try:
                n = sock.send(data[offset[0]:])
                offset[0] += n
                if offset[0] >= len(data):
                    self.remove_writer(sock.fileno())
                    fut.set_result(None)
            except (BlockingIOError, InterruptedError):
                return
            except FdRetirementError as error:
                fut.set_exception(error)
            except Exception as error:
                try:
                    self.remove_writer(sock.fileno())
                except FdRetirementError as cleanup_error:
                    fut.set_exception(cleanup_error)
                else:
                    fut.set_exception(error)

        self.add_writer(sock.fileno(), _send)
        return await fut

    async def sock_connect(self, sock, address):
        """Connect a socket to a remote address."""
        fut = self.create_future()

        try:
            sock.connect(address)
            fut.set_result(None)
            return await fut
        except (BlockingIOError, InterruptedError):
            pass

        def _connect():
            if fut.done():
                return
            try:
                err = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                if err != 0:
                    raise OSError(err, "Connect call failed", address)
            except Exception as error:
                try:
                    self.remove_writer(sock.fileno())
                except FdRetirementError as cleanup_error:
                    fut.set_exception(cleanup_error)
                else:
                    fut.set_exception(error)
                return
            try:
                self.remove_writer(sock.fileno())
            except FdRetirementError as error:
                fut.set_exception(error)
            else:
                fut.set_result(None)

        self.add_writer(sock.fileno(), _connect)
        return await fut

    async def sock_accept(self, sock):
        """Accept a connection on a socket."""
        fut = self.create_future()

        def _accept():
            if fut.done():
                return
            try:
                conn, address = sock.accept()
                conn.setblocking(False)
            except (BlockingIOError, InterruptedError):
                return
            except Exception as error:
                try:
                    self.remove_reader(sock.fileno())
                except FdRetirementError as cleanup_error:
                    fut.set_exception(cleanup_error)
                else:
                    fut.set_exception(error)
                return
            try:
                self.remove_reader(sock.fileno())
            except FdRetirementError as error:
                conn.close()
                fut.set_exception(error)
            else:
                fut.set_result((conn, address))

        self.add_reader(sock.fileno(), _accept)
        return await fut

    async def sock_sendfile(self, sock, file, offset=0, count=None, *, fallback=True):
        """Send a file through a socket."""
        raise NotImplementedError("sock_sendfile not implemented")

    # ========================================================================
    # Unix socket operations
    # ========================================================================

    async def create_unix_connection(
            self, protocol_factory, path=None, *,
            ssl=None, sock=None, server_hostname=None,
            ssl_handshake_timeout=None, ssl_shutdown_timeout=None):
        """Create a Unix socket connection."""
        from ._transport import ErlangSocketTransport

        if sock is None:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.setblocking(False)
            await self.sock_connect(sock, path)
        else:
            sock.setblocking(False)

        protocol = protocol_factory()
        transport = ErlangSocketTransport(self, sock, protocol)
        await transport._start()

        return transport, protocol

    async def create_unix_server(
            self, protocol_factory, path=None, *,
            sock=None, backlog=100, ssl=None,
            ssl_handshake_timeout=None, ssl_shutdown_timeout=None,
            start_serving=True):
        """Create a Unix socket server."""
        from ._transport import ErlangServer

        if sock is None:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.setblocking(False)
            try:
                os.unlink(path)
            except OSError:
                if os.path.exists(path):
                    raise
            sock.bind(path)
            sock.listen(backlog)
        else:
            sock.setblocking(False)

        server = ErlangServer(self, [sock], protocol_factory, ssl, backlog)
        if start_serving:
            server._start_serving()

        return server

    # ========================================================================
    # High-level connection methods
    # ========================================================================

    async def create_connection(
            self, protocol_factory, host=None, port=None,
            *, ssl=None, family=0, proto=0, flags=0, sock=None,
            local_addr=None, server_hostname=None,
            ssl_handshake_timeout=None, ssl_shutdown_timeout=None,
            happy_eyeballs_delay=None, interleave=None):
        """Create a streaming transport connection."""
        from ._transport import ErlangSocketTransport

        if sock is not None:
            sock.setblocking(False)
        else:
            infos = await self.getaddrinfo(
                host, port, family=family, type=socket.SOCK_STREAM,
                proto=proto, flags=flags)
            if not infos:
                raise OSError(f'getaddrinfo({host!r}) returned empty list')

            exceptions = []
            for family, type_, proto, cname, address in infos:
                sock = socket.socket(family, type_, proto)
                sock.setblocking(False)
                try:
                    await self.sock_connect(sock, address)
                    break
                except OSError as exc:
                    exceptions.append(exc)
                    sock.close()
                    sock = None

            if sock is None:
                if len(exceptions) == 1:
                    raise exceptions[0]
                raise OSError(f'Multiple exceptions: {exceptions}')

        protocol = protocol_factory()
        transport = ErlangSocketTransport(self, sock, protocol)

        try:
            await transport._start()
        except Exception:
            transport.close()
            raise

        return transport, protocol

    async def create_server(
            self, protocol_factory, host=None, port=None,
            *, family=socket.AF_UNSPEC, flags=socket.AI_PASSIVE,
            sock=None, backlog=100, ssl=None,
            reuse_address=None, reuse_port=None,
            ssl_handshake_timeout=None, ssl_shutdown_timeout=None,
            start_serving=True):
        """Create a TCP server."""
        from ._transport import ErlangServer

        if sock is not None:
            sockets = [sock]
        else:
            if host == '':
                hosts = [None]
            elif isinstance(host, str):
                hosts = [host]
            else:
                hosts = host if host else [None]

            sockets = []
            infos = []
            for h in hosts:
                info = await self.getaddrinfo(
                    h, port, family=family, type=socket.SOCK_STREAM,
                    flags=flags)
                infos.extend(info)

            completed = set()
            for family, type_, proto, cname, address in infos:
                key = (family, address)
                if key in completed:
                    continue
                completed.add(key)

                sock = socket.socket(family, type_, proto)
                sock.setblocking(False)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if reuse_port:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)

                try:
                    sock.bind(address)
                except OSError:
                    sock.close()
                    raise

                sock.listen(backlog)
                sockets.append(sock)

        server = ErlangServer(self, sockets, protocol_factory, ssl, backlog)
        if start_serving:
            server._start_serving()

        return server

    async def create_datagram_endpoint(
            self, protocol_factory,
            local_addr=None, remote_addr=None, *,
            family=0, proto=0, flags=0,
            reuse_address=None, reuse_port=None,
            allow_broadcast=None, sock=None):
        """Create datagram (UDP) connection."""
        from ._transport import ErlangDatagramTransport

        if sock is not None:
            sock.setblocking(False)
        else:
            if family == 0:
                family = socket.AF_INET

            sock = socket.socket(family, socket.SOCK_DGRAM, proto)
            sock.setblocking(False)

            if reuse_address:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

            if reuse_port:
                try:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                except (AttributeError, OSError):
                    pass

            if allow_broadcast:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

            if local_addr:
                sock.bind(local_addr)

            if remote_addr:
                sock.connect(remote_addr)

        protocol = protocol_factory()
        transport = ErlangDatagramTransport(self, sock, protocol, address=remote_addr)
        await transport._start()

        return transport, protocol

    # ========================================================================
    # Signal handling
    # ========================================================================

    def add_signal_handler(self, sig, callback, *args):
        """Add a signal handler.

        Note: Signal handling in Erlang integration is different from
        traditional Python. Signals are trapped by Erlang and dispatched
        to Python callbacks.
        """
        self._check_closed()

        # Import signal here to avoid issues on Windows
        import signal as signal_mod

        if sig not in (signal_mod.SIGINT, signal_mod.SIGTERM, signal_mod.SIGHUP):
            raise ValueError(f"Signal {sig} not supported")

        self._signal_handlers[sig] = (callback, args)

        # Register with Erlang's signal system
        try:
            self._pel._signal_add_handler(sig, self._next_id())
        except AttributeError:
            # Fallback: use Python's signal module
            signal_mod.signal(sig, lambda s, f: self.call_soon_threadsafe(callback, *args))

    def remove_signal_handler(self, sig):
        """Remove a signal handler."""
        if sig in self._signal_handlers:
            del self._signal_handlers[sig]

            try:
                self._pel._signal_remove_handler(sig)
            except AttributeError:
                import signal as signal_mod
                signal_mod.signal(sig, signal_mod.SIG_DFL)

            return True
        return False

    # ========================================================================
    # Subprocess (via Erlang ports)
    # ========================================================================

    async def subprocess_shell(
            self, protocol_factory, cmd, *,
            stdin=None, stdout=None, stderr=None, **kwargs):
        """Run a shell command in a subprocess."""
        from ._subprocess import create_subprocess_shell
        return await create_subprocess_shell(
            self, protocol_factory, cmd,
            stdin=stdin, stdout=stdout, stderr=stderr, **kwargs
        )

    async def subprocess_exec(
            self, protocol_factory, program, *args,
            stdin=None, stdout=None, stderr=None, **kwargs):
        """Execute a program in a subprocess."""
        from ._subprocess import create_subprocess_exec
        return await create_subprocess_exec(
            self, protocol_factory, program, *args,
            stdin=stdin, stdout=stdout, stderr=stderr, **kwargs
        )

    # ========================================================================
    # Error handling
    # ========================================================================

    def set_exception_handler(self, handler):
        """Set the exception handler."""
        self._exception_handler = handler

    def get_exception_handler(self):
        """Get the exception handler."""
        return self._exception_handler

    def default_exception_handler(self, context):
        """Default exception handler."""
        message = context.get('message', 'Unhandled exception')
        exception = context.get('exception')

        if exception is not None:
            import traceback
            exc_info = (type(exception), exception, exception.__traceback__)
            tb = ''.join(traceback.format_exception(*exc_info))
            print(f'{message}\n{tb}', file=sys.stderr)
        else:
            print(f'{message}', file=sys.stderr)

    def call_exception_handler(self, context):
        """Call the exception handler."""
        if self._exception_handler is not None:
            try:
                self._exception_handler(self, context)
            except Exception:
                self.default_exception_handler(context)
        else:
            self.default_exception_handler(context)

    # ========================================================================
    # Debug mode
    # ========================================================================

    def get_debug(self):
        """Return the debug mode setting."""
        return self._debug

    def set_debug(self, enabled):
        """Set the debug mode."""
        self._debug = enabled

    # ========================================================================
    # Internal methods
    # ========================================================================

    def _run_once(self, timeout_hint=None):
        """Run one iteration of the event loop.

        Args:
            timeout_hint: Optional timeout in ms. If 0, don't block waiting
                for I/O. Used by C code when coroutines were just scheduled.
        """
        # Update cached time at start of iteration (uvloop-style)
        self._cached_time = time.monotonic()

        # Reset wakeup coalescing flag so next call_soon_threadsafe will wake us
        self._wake_pending = False

        ready = self._ready
        popleft = self._ready_popleft
        return_handle = self._return_handle

        # Run all ready callbacks
        ntodo = len(ready)
        for _ in range(ntodo):
            if not ready:
                break
            handle = popleft()
            if handle._cancelled:
                if type(handle) is _PooledHandle:
                    self._rearm_fd_callback(handle._fd_callback_id)
                return_handle(handle)
                continue
            self._current_handle = handle
            try:
                handle._run()
            except Exception as e:
                self.call_exception_handler({
                    'message': 'Exception in callback',
                    'exception': e,
                    'handle': handle,
                })
            finally:
                self._current_handle = None
                return_handle(handle)

        self._prepare_timers()

        if timeout_hint is not None:
            # C code told us to use this timeout (e.g., 0 after scheduling coros)
            timeout = timeout_hint
        elif ready or self._stopping:
            timeout = 0
        else:
            # No timers - use longer poll timeout
            timeout = 1000

        if self._scheduled:
            delay = max(0, math.ceil(min(
                self._scheduled[0]._when - time.monotonic(), _MAX_TIMER_DELAY) * 1000))
            timeout = min(timeout, delay)
        timeout = min(timeout, _MAX_TIMER_DELAY * 1000)
        # Poll for events
        try:
            pending = self._pel._run_once_native_for(self._loop_capsule, timeout)
            dispatch = self._dispatch
            for callback_id, event_type in pending:
                dispatch(callback_id, event_type)
        except RuntimeError as e:
            raise RuntimeError(f"Event loop poll failed: {e}") from e
        self._prepare_timers()
        if timeout_hint is not None and not self._running:
            self._arm_timer_wakeup()

    def _prepare_timers(self):
        scheduled = self._scheduled
        if len(scheduled) > 100 and self._timer_cancelled_count > len(scheduled) * 0.5:
            live = []
            for handle in scheduled:
                if handle._cancelled:
                    handle._scheduled = False
                else:
                    live.append(handle)
            heapq.heapify(live)
            self._scheduled = scheduled = live
            self._timer_cancelled_count = 0
        else:
            while scheduled and scheduled[0]._cancelled:
                handle = heapq.heappop(scheduled)
                handle._scheduled = False
                self._timer_cancelled_count -= 1
        now = time.monotonic() + self._clock_resolution
        while scheduled and scheduled[0]._when <= now:
            handle = heapq.heappop(scheduled)
            handle._scheduled = False
            if handle._cancelled:
                self._timer_cancelled_count -= 1
            else:
                self._ready_append(handle)

    def _arm_timer_wakeup(self):
        if not self._scheduled:
            return
        deadline = self._scheduled[0]._when
        if self._timer_deadline is not None and deadline >= self._timer_deadline:
            return
        if self._timer_ref is not None:
            self._pel._cancel_timer_for(self._loop_capsule, self._timer_ref)
            self._timer_ref = None
            self._timer_deadline = None
        self._timer_callback_id = self._next_id()
        delay = max(1, math.ceil(min(
            deadline - time.monotonic(), _MAX_TIMER_DELAY) * 1000))
        self._timer_ref = self._pel._schedule_timer_for(
            self._loop_capsule, delay, self._timer_callback_id)
        self._timer_deadline = deadline

    def _dispatch(self, callback_id, event_type):
        """Dispatch a callback based on event type.

        Uses _callbacks_by_cid for O(1) lookup instead of two-level lookup.
        """
        if event_type == EVENT_TYPE_READ or event_type == EVENT_TYPE_WRITE:
            # O(1) direct lookup by callback_id
            entry = self._callbacks_by_cid.get(callback_id)
            if entry is not None:
                handle = self._get_handle(self._run_fd_callback, (callback_id,))
                handle._fd_callback_id = callback_id
                self._ready_append(handle)
        elif event_type == EVENT_TYPE_TIMER:
            if callback_id == self._timer_callback_id:
                self._timer_ref = None
                self._timer_deadline = None
                return
            handle = self._timers.pop(callback_id, None)
            if handle is not None and not handle._cancelled:
                self._ready_append(handle)

    def _run_fd_callback(self, callback_id: int) -> None:
        entry = self._callbacks_by_cid.get(callback_id)
        if entry is None:
            return
        try:
            if (
                entry.key not in self._fd_retirement_failed
                and entry.fd not in self._fd_publications
            ):
                entry.callback(*entry.args)
        finally:
            self._rearm_fd_callback(callback_id)

    def _rearm_fd_callback(self, callback_id: int) -> None:
        entry = self._callbacks_by_cid.get(callback_id)
        if entry is not None:
            self._pel._rearm_fd(entry.key, callback_id)

    def _get_ready_count(self):
        """Return the number of ready callbacks.

        Used by C code to check if there's more work to do.
        """
        return len(self._ready)

    def _check_closed(self):
        """Raise an error if the loop is closed."""
        if self._closed:
            raise RuntimeError('Event loop is closed')

    def _check_running(self):
        """Raise an error if the loop is already running."""
        if self._running:
            raise RuntimeError('This event loop is already running')

    def _timer_handle_cancelled(self, handle):
        """Called when a TimerHandle is cancelled."""
        if handle._scheduled:
            self._timer_cancelled_count += 1

    def _set_coroutine_origin_tracking(self, enabled):
        """Enable/disable coroutine origin tracking."""
        if enabled:
            sys.set_coroutine_origin_tracking_depth(1)
        else:
            sys.set_coroutine_origin_tracking_depth(0)

    # ========================================================================
    # Handle pool for reduced allocations
    # ========================================================================

    def _get_handle(self, callback, args, context=None):
        """Get a Handle from the pool or create a new one.

        This is a uvloop-style optimization to reduce allocations.
        Pooled handles are reused instead of creating new objects.
        """
        # Match Handle.__init__ behavior: copy current context if None
        if context is None:
            context = contextvars.copy_context()

        # Use try/except for thread-safety in free-threaded Python
        # The pool check and pop are not atomic, so another thread could
        # empty the pool between the check and pop
        try:
            handle = self._handle_pool.pop()
            handle._callback = callback
            handle._args = args
            handle._cancelled = False
            handle._context = context
            return handle
        except IndexError:
            return _PooledHandle(callback, args, self, context)

    def _return_handle(self, handle):
        """Return a Handle to the pool for reuse.

        Clears all references to allow GC of callback/args/context.

        IMPORTANT: TimerHandle objects must NOT be pooled because asyncio.sleep
        keeps a reference to the timer handle and cancels it in a finally block.
        If the TimerHandle is recycled and reused for another callback, the
        cancel() call will incorrectly cancel the new callback.
        """
        # Only handles created by _dispatch are recycled (see _PooledHandle);
        # call_soon/call_at handles are held by callers who may cancel them
        if type(handle) is not _PooledHandle:
            return

        if len(self._handle_pool) < self._handle_pool_max:
            handle._callback = None
            handle._args = None
            handle._context = None
            self._handle_pool.append(handle)

    # ========================================================================
    # Executor methods
    # ========================================================================

    def run_in_executor(self, executor, func, *args):
        """Run a function in an executor."""
        self._check_closed()
        if executor is None:
            executor = self._get_default_executor()
        return asyncio.wrap_future(
            executor.submit(func, *args),
            loop=self
        )

    def _get_default_executor(self):
        """Get or create the default executor."""
        if self._default_executor is None:
            from concurrent.futures import ThreadPoolExecutor
            self._default_executor = ThreadPoolExecutor()
        return self._default_executor

    def set_default_executor(self, executor):
        """Set the default executor."""
        self._default_executor = executor

    # ========================================================================
    # DNS resolution
    # ========================================================================

    async def getaddrinfo(self, host, port, *, family=0, type=0, proto=0, flags=0):
        """Resolve host/port to address info."""
        return await self.run_in_executor(
            None, socket.getaddrinfo, host, port, family, type, proto, flags
        )

    async def getnameinfo(self, sockaddr, flags=0):
        """Resolve socket address to host/port."""
        return await self.run_in_executor(None, socket.getnameinfo, sockaddr, flags)


class _MockLoopCapsule:
    """Mock loop capsule for testing."""

    def __init__(self):
        self.readers = {}
        self.writers = {}
        self.pending = []
        self._counter = 0
        self.driver_lock = threading.Lock()
        self.driver_token: object | None = None
        self.driver_thread = 0
        self._fd_resources = {}  # fd_key -> {fd, read_active, write_active, read_cid, write_cid}


class _MockNifModule:
    """Mock NIF module for testing without actual Erlang integration."""

    def __init__(self):
        self._fd_by_key = {}
        self._fd_callback_sequence = 0

    def _new_fd_callback_id(self) -> int:
        self._fd_callback_sequence += 1
        return (1 << 62) | self._fd_callback_sequence

    def _is_initialized(self):
        return True

    def _has_loop_ref(self, capsule):
        return True

    def _claim_driver_session(self, capsule, owner, allow_current=False):
        thread = threading.get_ident()
        with capsule.driver_lock:
            if capsule.driver_token is not None:
                if allow_current and capsule.driver_thread == thread:
                    return capsule.driver_token, False
                raise RuntimeError("Native loop driver session is already claimed or unavailable")
            capsule.driver_token = object()
            capsule.driver_thread = thread
            return capsule.driver_token, True

    def _release_driver_session(self, capsule, owner, token):
        with capsule.driver_lock:
            if capsule.driver_token is not token or capsule.driver_thread != threading.get_ident():
                raise RuntimeError("Driver session release requires its stopped exact owner")
            capsule.driver_token = None
            capsule.driver_thread = 0

    def _loop_new(self):
        return _MockLoopCapsule()

    def _loop_destroy(self, capsule):
        pass

    def _run_once_native_for(self, capsule, timeout_ms):
        time.sleep(min(timeout_ms, 10) / 1000.0)
        result = []
        for callback_id, event_type in capsule.pending:
            if isinstance(event_type, str):
                if event_type == 'read':
                    event_type = EVENT_TYPE_READ
                elif event_type == 'write':
                    event_type = EVENT_TYPE_WRITE
                else:
                    event_type = EVENT_TYPE_TIMER
            result.append((callback_id, event_type))
        capsule.pending.clear()
        return result

    def _wakeup_for(self, capsule):
        pass

    def _add_reader_for(self, capsule: _MockLoopCapsule, fd: int, callback_id: int) -> int:
        capsule._counter += 1
        capsule.readers[fd] = (callback_id, capsule._counter)
        self._fd_by_key[capsule._counter] = fd
        return capsule._counter

    def _remove_reader_for(self, capsule, fd_key):
        for fd, (cid, key) in list(capsule.readers.items()):
            if key == fd_key:
                del capsule.readers[fd]
                break

    def _add_writer_for(self, capsule: _MockLoopCapsule, fd: int, callback_id: int) -> int:
        capsule._counter += 1
        capsule.writers[fd] = (callback_id, capsule._counter)
        self._fd_by_key[capsule._counter] = fd
        return capsule._counter

    def _remove_writer_for(self, capsule, fd_key):
        for fd, (cid, key) in list(capsule.writers.items()):
            if key == fd_key:
                del capsule.writers[fd]
                break

    def _update_fd_read(self, fd_key, callback_id):
        """Update read callback on existing fd_resource."""
        pass

    def _rearm_fd(self, fd_key, callback_id):
        pass

    def _update_fd_write(self, fd_key, callback_id):
        """Update write callback on existing fd_resource."""
        pass

    def _clear_fd_read(self, fd_key):
        """Clear read monitoring on fd_resource."""
        pass

    def _clear_fd_write(self, fd_key):
        """Clear write monitoring on fd_resource."""
        pass

    def _release_fd_resource(self, fd_key: int, take_ownership: bool = False) -> str:
        fd = self._fd_by_key.pop(fd_key, None)
        return "absent" if fd is None else "poll_closed"

    def _schedule_timer_for(self, capsule, delay_ms, callback_id):
        return callback_id

    def _cancel_timer_for(self, capsule, timer_ref):
        pass


# =============================================================================
# Async coroutine wrapper for result delivery
# =============================================================================

async def _run_and_send(coro, caller_pid, ref, reply_on_success=True):
    """Run a coroutine and send the result to an Erlang caller via erlang.send().

    This function wraps a coroutine and sends its result (or error) to the
    specified Erlang process using erlang.send(). Used by the async worker
    backend to deliver results without pthread polling.

    Args:
        coro: The coroutine to run
        caller_pid: An erlang.Pid object for the caller process
        ref: A reference to include in the result message
        reply_on_success: When false, report failures with an undefined reference

    The result message format is:
        (async_result, ref, (ok, result)) - on success
        (async_result, ref, (error, error_str)) - on failure

    Note: Uses cached atom() to create atoms for message keys, since Python
    strings become Erlang binaries but the await function expects atoms.
    """
    import erlang
    from . import atom  # Use cached version from _erlang_impl

    loop = asyncio.get_running_loop()
    observer = loop._shutdown_observer if isinstance(loop, ErlangEventLoop) else None
    current = asyncio.current_task()
    if observer is not None and current is not None:
        observer.observe(current)

    # Create atoms for message keys (strings become binaries, await expects atoms)
    async_result = atom('async_result')
    try:
        result = await coro
        if reply_on_success:
            try:
                erlang.send(caller_pid, (async_result, ref, (atom('ok'), result)))
            except erlang.ProcessError:
                pass  # Caller gone, nothing to do
    except asyncio.CancelledError:
        try:
            reply_ref = ref if reply_on_success else atom('undefined')
            erlang.send(caller_pid, (async_result, reply_ref, (atom('error'), 'cancelled')))
        except erlang.ProcessError:
            pass  # Caller gone, nothing to do
    except Exception as e:
        active_observer = loop._shutdown_observer if isinstance(loop, ErlangEventLoop) else None
        if active_observer is not None:
            active_observer.failed = True
        import traceback
        tb = traceback.format_exc()
        try:
            reply_ref = ref if reply_on_success else atom('undefined')
            erlang.send(caller_pid, (async_result, reply_ref,
                                     (atom('error'), f'{type(e).__name__}: {e}\n{tb}')))
        except erlang.ProcessError:
            pass  # Caller gone, nothing to do

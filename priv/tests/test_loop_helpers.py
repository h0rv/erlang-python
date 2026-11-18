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

"""Unit tests for the worker loop entry points behind py_context:start_loop/1.

_run_loop_forever() runs an ErlangEventLoop on the calling thread until
_stop_loop() (a coroutine scheduled on it) stops it. Runs inside the BEAM
through tests.ct_runner in an owngil context (its own interpreter, no other
ErlangEventLoop alive), so it exercises the real py_event_loop module.
"""

import asyncio
import threading
import unittest

import _erlang_impl as impl
import py_event_loop as native


class TestLoopHelpers(unittest.TestCase):

    def test_run_forever_returns_after_stop(self):
        started = threading.Event()
        result = {}
        capsule = native._get_global_loop_capsule()
        loop = impl.ErlangEventLoop(capsule)
        loop.call_soon(started.set)

        def runner():
            result['ret'] = impl._run_loop_forever(capsule=capsule)

        t = threading.Thread(target=runner)
        t.start()
        try:
            self.assertTrue(started.wait(5))
            self.assertTrue(loop.is_running())
        finally:
            if not loop.is_closed():
                loop.call_soon_threadsafe(lambda: loop.create_task(impl._stop_loop()))
            t.join(5)
        self.assertFalse(t.is_alive())
        self.assertEqual(result['ret'], 'stopped')
        self.assertTrue(loop.is_closed())
        # the current event loop is cleared, a new one can be created
        with self.assertRaises(RuntimeError):
            asyncio.get_running_loop()
        loop2 = impl.new_event_loop()
        loop2.close()

    def test_stop_loop_outside_loop_raises(self):
        coro = impl._stop_loop()
        with self.assertRaises(RuntimeError):
            coro.send(None)  # no running loop
        coro.close()

    def test_python_loops_run_independently(self):
        """Python-created loops do not take over each other's resources."""
        loop = impl.new_event_loop()
        started = threading.Event()
        loop.call_soon(started.set)
        t = threading.Thread(target=loop.run_forever)
        t.start()
        try:
            self.assertTrue(started.wait(5))
            second = impl.new_event_loop()
            try:
                self.assertEqual(second.run_until_complete(asyncio.sleep(0.001, 42)), 42)
                self.assertTrue(loop.is_running())
            finally:
                second.close()
        finally:
            loop.call_soon_threadsafe(loop.stop)
            t.join(5)
            loop.close()
        self.assertFalse(t.is_alive())


if __name__ == '__main__':
    unittest.main()


class TestHandleReuse(unittest.TestCase):
    """call_soon/call_at handles are the caller's: cancelling one after it
    ran must not touch a later callback (the handle pool used to recycle
    them, so asyncio.sleep's cancel in its finally block killed whichever
    callback had been given the recycled handle)."""

    def _loop(self):
        return impl.new_event_loop()

    def test_cancel_after_run_does_not_kill_next_callback(self):
        loop = self._loop()
        seen = []
        try:
            h1 = loop.call_soon(seen.append, 1)
            loop.call_soon(loop.stop)
            loop.run_forever()
            self.assertEqual(seen, [1])
            # h1 ran; a stale cancel must be a no-op
            h1.cancel()
            loop.call_soon(seen.append, 2)
            loop.call_soon(loop.stop)
            loop.run_forever()
            self.assertEqual(seen, [1, 2])
        finally:
            loop.close()

    def test_zero_delay_call_later_returns_timer_handle(self):
        loop = self._loop()
        seen = []
        try:
            h = loop.call_later(0, seen.append, 'x')
            self.assertIsInstance(h, asyncio.TimerHandle)
            loop.call_soon(loop.stop)
            loop.run_forever()
            self.assertEqual(seen, ['x'])
            h.cancel()  # after it ran, no effect on anything else
            loop.call_soon(seen.append, 'y')
            loop.call_soon(loop.stop)
            loop.run_forever()
            self.assertEqual(seen, ['x', 'y'])
        finally:
            loop.close()

    def test_many_sleeps_all_wake(self):
        """500 concurrent sleep(0.001): every one comes back, whether the
        delay rounds to a timer or to the next iteration."""
        loop = self._loop()
        woke = []

        async def one(i):
            await asyncio.sleep(0.001)
            woke.append(i)

        async def main():
            await asyncio.gather(*(one(i) for i in range(500)))

        try:
            loop.run_until_complete(main())
        finally:
            loop.close()
        self.assertEqual(sorted(woke), list(range(500)))

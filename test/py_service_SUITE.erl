-module(py_service_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([owned_cleanup/1, original_failure/1, foreign_loop_rejected/1]).

all() -> [owned_cleanup, original_failure, foreign_loop_rejected].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    {ok, Ctx} = py_context:new(#{mode => worker}),
    ok = py:exec(Ctx, <<"
import sys
import types
service_probe = types.ModuleType('_service_integration_probe')
exec('''
import asyncio
from erlang_services import ServiceBusyError, ServiceSlot

async def held(started: asyncio.Event, cleanup: asyncio.Event,
               finish: asyncio.Event, state: list[object], marker: object) -> None:
    assert state[0] is marker
    started.set()
    try:
        await asyncio.Event().wait()
    finally:
        cleanup.set()
        await finish.wait()
        state.append(marker)

async def complete() -> None:
    return None

async def fail(error: ValueError) -> None:
    raise error

async def owned_cleanup() -> bool:
    slot = ServiceSlot(capacity=1)
    started, cleanup, finish = asyncio.Event(), asyncio.Event(), asyncio.Event()
    marker = object()
    state = [marker]
    ref = slot.start(held, started, cleanup, finish, state, marker)
    await started.wait()
    try:
        await ref.wait(timeout=0)
    except TimeoutError:
        pass
    else:
        raise AssertionError('live service wait returned')
    waiter = asyncio.create_task(ref.wait())
    await asyncio.sleep(0)
    waiter.cancel()
    try:
        await waiter
    except asyncio.CancelledError:
        pass
    assert not cleanup.is_set()
    for _ in range(2):
        try:
            await ref.stop(timeout=0)
        except TimeoutError:
            pass
        else:
            raise AssertionError('unfinished cleanup acknowledged')
        await cleanup.wait()
        assert ref.state == 'running'
        try:
            slot.start(complete)
        except ServiceBusyError:
            pass
        else:
            raise AssertionError('running cleanup freed slot')
    finish.set()
    await ref.stop(timeout=1)
    assert ref.state == 'cancelled'
    assert len(state) == 2 and state[1] is marker
    replacement = slot.start(complete)
    await replacement.wait(timeout=1)
    assert replacement.state == 'completed'
    assert replacement is not ref and ref.state == 'cancelled'
    return True

async def original_failure() -> bool:
    slot = ServiceSlot(capacity=1)
    error = ValueError(b'original')
    ref = slot.start(fail, error)
    for _ in range(2):
        try:
            await ref.wait(timeout=1)
        except ValueError as observed:
            assert observed is error
        else:
            raise AssertionError('failure lost')
    assert ref.state == 'failed'
    return True

async def foreign_loop() -> bool:
    try:
        ServiceSlot(capacity=1).start(complete)
    except RuntimeError:
        return True
    raise AssertionError('non-native loop accepted')

def foreign_loop_rejected() -> bool:
    return asyncio.run(foreign_loop())
''', service_probe.__dict__)
sys.modules[service_probe.__name__] = service_probe
">>),
    [{context, Ctx} | Config].

end_per_suite(Config) ->
    Ctx = proplists:get_value(context, Config),
    ok = py:exec(Ctx, <<"import sys; del sys.modules['_service_integration_probe']">>),
    py_context:stop(Ctx),
    ok = application:stop(erlang_python).

owned_cleanup(_Config) -> check(owned_cleanup).
original_failure(_Config) -> check(original_failure).
foreign_loop_rejected(Config) ->
    Ctx = proplists:get_value(context, Config),
    {ok, true} = py:call(Ctx, '_service_integration_probe', foreign_loop_rejected, []),
    ok.

check(Function) ->
    Ref = py_event_loop:create_task('_service_integration_probe', Function, []),
    {ok, true} = py_event_loop:await(Ref, 5000),
    ok.

-module(py_actor_contract_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    return_ref_option/1,
    async_method_result/1,
    async_submission_is_not_serialized/1,
    owner_state_release/1
]).

all() ->
    [return_ref_option, async_method_result,
     async_submission_is_not_serialized, owner_state_release].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    {ok, _} = py:start_contexts(#{contexts => 1, mode => worker}),
    Config.

end_per_suite(_Config) ->
    py:stop_contexts(),
    ok.

return_ref_option(_Config) ->
    Ctx = py:context(1),
    {ok, [1, 2, 3]} = py:call(Ctx, builtins, list, [[1, 2, 3]], #{return => ref}),
    ok.

async_method_result(_Config) ->
    Ctx = py:context(1),
    ok = py:exec(Ctx, <<"
class Counter:
    def __init__(self):
        self.value = 0
    async def add(self, amount, *, label):
        self.value += amount
        return self.value
counter = Counter()
pending = counter.add(2, label='visits')
">>),
    try
        {ok, Repr} = py:eval(Ctx, <<"pending">>),
        true = is_binary(Repr),
        {ok, 0} = py:eval(Ctx, <<"counter.value">>)
    after
        ok = py:exec(Ctx, <<"pending.close(); del pending, counter">>)
    end,
    ok.

async_submission_is_not_serialized(_Config) ->
    Ctx = py:context(1),
    ok = py:exec(Ctx, <<"
import sys
import types
probe = types.ModuleType('_actor_contract_probe')
exec('''
import asyncio
class Counter:
    def __init__(self):
        self.value = 0
        self.started = 0
        self.ready = asyncio.Event()
    async def add(self, amount, *, label):
        old = self.value
        self.started += 1
        if self.started == 8:
            self.ready.set()
        await self.ready.wait()
        self.value = old + amount
        return self.value
counter = Counter()
async def add(amount, *, label):
    return await counter.add(amount, label=label)
''', probe.__dict__)
sys.modules[probe.__name__] = probe
">>),
    try
        Refs = [begin
            {ok, Ref} = py_context:submit(Ctx, '_actor_contract_probe', add,
                                         [1], #{<<"label">> => <<"visits">>}),
            Ref
        end || _ <- lists:seq(1, 8)],
        Results = [begin {ok, Value} = py_event_loop:await(Ref, 5000), Value end
                   || Ref <- Refs],
        %% All requests observe the same old value while awaiting. Submission
        %% alone does not supply an actor's serial execution policy.
        [1] = lists:usort(Results)
    after
        ok = py:exec(Ctx, <<"del sys.modules['_actor_contract_probe']; del probe">>)
    end,
    ok.

owner_state_release(_Config) ->
    Ctx = py:context(1),
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        ok = py:exec(Ctx, <<"
import builtins
import weakref
class State:
    pass
state = State()
builtins._actor_contract_state = weakref.ref(state)
">>),
        Parent ! {ready, self()},
        receive stop -> ok end
    end),
    receive {ready, Pid} -> ok after 5000 -> error(owner_start_timeout) end,
    Pid ! stop,
    receive {'DOWN', Mon, process, Pid, normal} -> ok
    after 5000 -> error(owner_stop_timeout) end,
    %% DOWN establishes owner death, but environment release is resource GC.
    true = erlang:garbage_collect(Ctx),
    ok = py:exec(Ctx, <<"import gc; import builtins; gc.collect()">>),
    try
        {ok, true} = py:eval(Ctx, <<"builtins._actor_contract_state() is None">>)
    after
        ok = py:exec(Ctx, <<"del builtins._actor_contract_state">>)
    end,
    ok.

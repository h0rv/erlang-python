-module(py_local_object_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([values/1, async_result_and_exception/1, context_identity/1,
         serialized_awaits/1, source_owner_death/1, cleanup/1,
         abandoned_waits/1, actor_processes/1, actor_policy/1, interpreter_validation/1,
         actor_death_cleanup/1, serialization/1, driver_compatibility/1]).

all() -> [values, async_result_and_exception, context_identity,
          serialized_awaits, source_owner_death, cleanup,
          abandoned_waits, actor_processes, actor_policy, interpreter_validation,
          actor_death_cleanup, serialization, driver_compatibility].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    {ok, Ctx} = py_context:new(#{mode => worker}),
    [{context, Ctx} | Config].

end_per_suite(Config) ->
    py_context:stop(proplists:get_value(context, Config)).

context(Config) -> proplists:get_value(context, Config).

env(Ctx) ->
    {ok, Env} = py_context:create_local_env(Ctx),
    Env.

ref(Ctx, Env, Code) -> ref(Ctx, Env, Code, #{}).
ref(Ctx, Env, Code, Bindings) ->
    {ok, Ref} = py_context:eval_ref(Ctx, Code, Bindings, Env),
    Ref.

check(Ctx, Env, Condition, Bindings) ->
    ref(Ctx, Env, <<"None if (", Condition/binary,
        ") else (_ for _ in ()).throw(AssertionError('reference check'))">>, Bindings),
    ok.

counter(Ctx, Env) ->
    ok = py_context:exec(Ctx, <<"
import asyncio
class Counter:
    def __init__(self):
        self.value = 0
        self.loop = None
    async def add(self, amount, *, label):
        current = asyncio.get_running_loop()
        if self.loop is None:
            self.loop = current
        assert self.loop is current
        old = self.value
        await asyncio.sleep(0.001)
        self.value = old + amount
        return (self.value, label)
    async def fail(self):
        self.value += 10
        await asyncio.sleep(0.001)
        raise ValueError(b'original bytes')
">>, Env),
    {ref(Ctx, Env, <<"Counter()">>), ref(Ctx, Env, <<"Counter.add">>)}.

driver_compatibility(Config) ->
    Ctx = context(Config),
    {ok, 42} = py_context:submit_await(Ctx, asyncio, sleep, [0.001],
                                      #{<<"result">> => 42}, 5000),
    Env = env(Ctx),
    ok = py_context:start_loop(Ctx),
    try
        {error, loop_running} = py_context:eval_ref(Ctx, <<"1">>, #{}, Env)
    after ok = py_context:stop_loop(Ctx) end,
    ref(Ctx, Env, <<"1">>),
    ok.

serialization(Config) ->
    Ctx = context(Config),
    Env = env(Ctx),
    Value = ref(Ctx, Env, <<"object()">>),
    Reconstructed = binary_to_term(term_to_binary(Value), [safe]),
    Same = ref(Ctx, Env, <<"value">>, #{<<"value">> => Reconstructed}),
    ok = check(Ctx, Env, <<"value is same">>, #{<<"value">> => Value, <<"same">> => Same}),
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        SourceEnv = env(Ctx),
        ok = py_context:exec(Ctx, <<"
import builtins
import weakref
class State:
    pass
">>, SourceEnv),
        State = ref(Ctx, SourceEnv, <<"State()">>),
        ref(Ctx, SourceEnv, <<"setattr(builtins, '_serialized_weakref', weakref.ref(state))">>,
            #{<<"state">> => State}),
        Parent ! {serialized, self(), term_to_binary(State)}
    end),
    Binary = receive {serialized, Pid, B} -> B after 5000 -> error(owner_timeout) end,
    receive {'DOWN', Mon, process, Pid, normal} -> ok after 5000 -> error(owner_timeout) end,
    true = erlang:garbage_collect(Ctx),
    ok = py_context:exec(Ctx, <<"import builtins; import gc; gc.collect()">>, Env),
    try
        ok = check(Ctx, Env, <<"builtins._serialized_weakref() is None">>, #{}),
        Expired = binary_to_term(Binary, [safe]),
        {python_error, Error} = py_context:eval_ref(Ctx, <<"value">>, #{<<"value">> => Expired}, Env),
        check(Ctx, Env, <<"type(error) is TypeError">>, #{<<"error">> => Error})
    after py_context:exec(Ctx, <<"del builtins._serialized_weakref">>, Env) end.

values(Config) ->
    Ctx = context(Config),
    Env = env(Ctx),
    Value = ref(Ctx, Env, <<"(b'visits', 'visits', __import__('threading').Lock())">>),
    Same = ref(Ctx, Env, <<"value">>, #{<<"value">> => Value}),
    ok = check(Ctx, Env, <<"value is same and type(value[0]) is bytes and type(value[1]) is str">>,
               #{<<"value">> => Value, <<"same">> => Same}),
    Func = ref(Ctx, Env, <<"lambda value: value">>),
    Args = ref(Ctx, Env, <<"(value[2],)">>, #{<<"value">> => Value}),
    Kwargs = ref(Ctx, Env, <<"{}">>),
    {ok, Result} = py_context:apply_ref(Ctx, Func, Args, Kwargs, Env),
    check(Ctx, Env, <<"result is value[2]">>, #{<<"value">> => Value, <<"result">> => Result}).

async_result_and_exception(Config) ->
    Ctx = context(Config),
    Env = env(Ctx),
    {State, Method} = counter(Ctx, Env),
    Args = ref(Ctx, Env, <<"(state, 2)">>, #{<<"state">> => State}),
    Kwargs = ref(Ctx, Env, <<"{'label': b'visits'}">>),
    {ok, Result} = py_context:apply_ref(Ctx, Method, Args, Kwargs, Env),
    ok = check(Ctx, Env, <<"result == (2, b'visits') and type(result[1]) is bytes">>,
               #{<<"result">> => Result}),
    Fail = ref(Ctx, Env, <<"Counter.fail">>),
    FailArgs = ref(Ctx, Env, <<"(state,)">>, #{<<"state">> => State}),
    Empty = ref(Ctx, Env, <<"{}">>),
    {python_error, Error} = py_context:apply_ref(Ctx, Fail, FailArgs, Empty, Env),
    check(Ctx, Env, <<"type(error) is ValueError and error.args == (b'original bytes',) "
                     "and error.__traceback__ is not None">>, #{<<"error">> => Error}).

context_identity(Config) ->
    Ctx = context(Config),
    Env = env(Ctx),
    Value = ref(Ctx, Env, <<"object()">>),
    {ok, Other} = py_context:new(#{mode => worker}),
    try
        OtherEnv = env(Other),
        {python_error, Error} = py_context:eval_ref(
            Other, <<"value">>, #{<<"value">> => Value}, OtherEnv),
        check(Other, OtherEnv, <<"type(error) is ValueError">>, #{<<"error">> => Error})
    after py_context:stop(Other) end.

serialized_awaits(Config) ->
    Ctx = context(Config),
    Env = env(Ctx),
    {State, Method} = counter(Ctx, Env),
    Args = ref(Ctx, Env, <<"(state, 1)">>, #{<<"state">> => State}),
    Kwargs = ref(Ctx, Env, <<"{'label': 'visits'}">>),
    Parent = self(),
    Pids = [spawn_monitor(fun() ->
        Result = py_context:apply_ref(Ctx, Method, Args, Kwargs, Env),
        Parent ! {result, self(), Result}
    end) || _ <- lists:seq(1, 16)],
    lists:foreach(fun({Pid, Mon}) ->
        receive {result, Pid, {ok, _}} -> ok after 10000 -> error(call_timeout) end,
        receive {'DOWN', Mon, process, Pid, normal} -> ok
        after 10000 -> error(caller_timeout) end
    end, Pids),
    check(Ctx, Env, <<"state.value == 16">>, #{<<"state">> => State}).

source_owner_death(Config) ->
    Ctx = context(Config),
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Env = env(Ctx),
        ok = py_context:exec(Ctx, <<"base = 40\ndef add(x):\n    return base + x">>, Env),
        Func = ref(Ctx, Env, <<"add">>),
        Parent ! {retained, self(), Func}
    end),
    Func = receive {retained, Pid, F} -> F after 5000 -> error(owner_timeout) end,
    receive {'DOWN', Mon, process, Pid, normal} -> ok after 5000 -> error(owner_timeout) end,
    Env = env(Ctx),
    Args = ref(Ctx, Env, <<"(2,)">>),
    Kwargs = ref(Ctx, Env, <<"{}">>),
    {ok, Result} = py_context:apply_ref(Ctx, Func, Args, Kwargs, Env),
    check(Ctx, Env, <<"result == 42">>, #{<<"result">> => Result}).

cleanup(Config) ->
    Ctx = context(Config),
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Env = env(Ctx),
        ok = py_context:exec(Ctx, <<"
import builtins
import weakref
class State:
    pass
">>, Env),
        State = ref(Ctx, Env, <<"State()">>),
        ref(Ctx, Env, <<"setattr(builtins, '_local_object_weakref', weakref.ref(state))">>,
            #{<<"state">> => State}),
        Parent ! {ready, self()}
    end),
    receive {ready, Pid} -> ok after 5000 -> error(owner_timeout) end,
    receive {'DOWN', Mon, process, Pid, normal} -> ok after 5000 -> error(owner_timeout) end,
    true = erlang:garbage_collect(Ctx),
    Env = env(Ctx),
    ok = py_context:exec(Ctx, <<"import builtins; import gc; gc.collect()">>, Env),
    try check(Ctx, Env, <<"builtins._local_object_weakref() is None">>, #{})
    after py_context:exec(Ctx, <<"del builtins._local_object_weakref">>, Env) end.

abandoned_waits(Config) ->
    {message_queue_len, Before} = process_info(self(), message_queue_len),
    Ctx = context(Config),
    Env = env(Ctx),
    {ok, _} = py_context:eval(Ctx, <<"globals().__setitem__('notify', pid)">>,
                            #{<<"pid">> => self()}, infinity, Env),
    ok = py_context:exec(Ctx, <<"
import asyncio
import erlang
effects = 0
async def slow():
    global effects
    erlang.send(notify, (erlang.atom('started'),))
    await asyncio.sleep(0.03)
    effects += 1
    return effects
">>, Env),
    Func = ref(Ctx, Env, <<"slow">>),
    Args = ref(Ctx, Env, <<"()">>),
    Kwargs = ref(Ctx, Env, <<"{}">>),
    {error, timeout} = py_context:apply_ref(Ctx, Func, Args, Kwargs, Env, 1),
    receive {started} -> ok after 5000 -> error(start_timeout) end,
    ok = check(Ctx, Env, <<"effects == 1">>, #{}),
    {Pid, Mon} = spawn_monitor(fun() ->
        py_context:apply_ref(Ctx, Func, Args, Kwargs, Env)
    end),
    receive {started} -> ok after 5000 -> error(start_timeout) end,
    exit(Pid, kill),
    receive {'DOWN', Mon, process, Pid, killed} -> ok after 5000 -> error(death_timeout) end,
    ok = check(Ctx, Env, <<"effects == 2">>, #{}),
    {message_queue_len, Before} = process_info(self(), message_queue_len),
    ok.

actor_processes(Config) ->
    Ctx = context(Config),
    Env = env(Ctx),
    {_Unused, Method} = counter(Ctx, Env),
    Factory = ref(Ctx, Env, <<"Counter">>),
    {ok, First} = py_object_actor:start_link(Ctx, Factory, [Method], unbounded),
    {ok, Second} = py_object_actor:start_link(Ctx, Factory, [Method], unbounded),
    Args = ref(Ctx, Env, <<"(1,)">>),
    Kwargs = ref(Ctx, Env, <<"{'label': b'visits'}">>),
    try
        Parent = self(),
        Pids = [spawn_monitor(fun() ->
            Result = py_object_actor:call(First, Method, Args, Kwargs, 5000),
            Parent ! {result, self(), Result}
        end) || _ <- lists:seq(1, 16)],
        lists:foreach(fun({Pid, Mon}) ->
            receive {result, Pid, {ok, _}} -> ok after 10000 -> error(call_timeout) end,
            receive {'DOWN', Mon, process, Pid, normal} -> ok
            after 10000 -> error(caller_timeout) end
        end, Pids),
        Zero = ref(Ctx, Env, <<"(0,)">>),
        {ok, Final} = py_object_actor:call(First, Method, Zero, Kwargs, 5000),
        ok = check(Ctx, Env, <<"value == (16, b'visits')">>, #{<<"value">> => Final}),
        {ok, Separate} = py_object_actor:call(Second, Method, Args, Kwargs, 5000),
        ok = check(Ctx, Env, <<"value == (1, b'visits')">>, #{<<"value">> => Separate}),
        Free = ref(Ctx, Env, <<"Counter.fail">>),
        {error, method_not_registered} = py_object_actor:call(First, Free, Zero, Kwargs, 5000)
    after
        py_object_actor:stop(First),
        py_object_actor:stop(Second)
    end,
    try py_object_actor:call(First, Method, Args, Kwargs, 100) of
        _ -> error(stale_pid_accepted)
    catch exit:{noproc, _} -> ok end,
    Fail = ref(Ctx, Env, <<"Counter.fail">>),
    {ok, Third} = py_object_actor:start_link(Ctx, Factory, [Method, Fail], unbounded),
    try
        EmptyArgs = ref(Ctx, Env, <<"()">>),
        EmptyKwargs = ref(Ctx, Env, <<"{}">>),
        {python_error, Error} = py_object_actor:call(Third, Fail, EmptyArgs, EmptyKwargs, 5000),
        ok = check(Ctx, Env, <<"type(error) is ValueError">>, #{<<"error">> => Error}),
        {ok, Changed} = py_object_actor:call(Third, Method, Args, Kwargs, 5000),
        check(Ctx, Env, <<"value == (11, b'visits')">>, #{<<"value">> => Changed})
    after py_object_actor:stop(Third) end.

actor_policy(Config) ->
    Ctx = context(Config),
    Env = env(Ctx),
    {_Unused, Method} = counter(Ctx, Env),
    Factory = ref(Ctx, Env, <<"Counter">>),
    {error, admission_unavailable} = py_object_actor:start_link(
        Ctx, Factory, [Method], #{capacity => 1, max_bytes => 1024}),
    Bad = ref(Ctx, Env, <<"lambda state: state.value">>),
    %% Failed linked startup also sends an exit signal to the caller.
    %% Registration checks class membership, not just callable compatibility.
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        Result = py_object_actor:start_link(Ctx, Factory, [Bad], unbounded),
        Parent ! {registration_result, self(), Result}
    end),
    receive {registration_result, Pid, {error, {python_error, _}}} -> ok
    after 5000 -> error(registration_timeout) end,
    receive {'DOWN', Mon, process, Pid, normal} -> ok
    after 5000 -> error(registration_owner_timeout) end.

actor_death_cleanup(Config) ->
    Ctx = context(Config),
    Env = env(Ctx),
    {ok, _} = py_context:eval(Ctx, <<"globals().__setitem__('notify', pid)">>,
                            #{<<"pid">> => self()}, infinity, Env),
    ok = py_context:exec(Ctx, <<"
import asyncio
import builtins
import erlang
import weakref
class Tracked:
    def __init__(self):
        builtins._tracked_actor = weakref.ref(self)
    async def run(self):
        erlang.send(notify, (erlang.atom('actor_started'),))
        await asyncio.sleep(0.03)
        return 1
">>, Env),
    Factory = ref(Ctx, Env, <<"Tracked">>),
    Method = ref(Ctx, Env, <<"Tracked.run">>),
    Args = ref(Ctx, Env, <<"()">>),
    Kwargs = ref(Ctx, Env, <<"{}">>),
    {ok, Actor} = py_object_actor:start_link(Ctx, Factory, [Method], unbounded),
    unlink(Actor),
    Mon = erlang:monitor(process, Actor),
    {Caller, CallerMon} = spawn_monitor(fun() ->
        py_object_actor:call(Actor, Method, Args, Kwargs, infinity)
    end),
    receive {actor_started} -> ok after 5000 -> error(start_timeout) end,
    exit(Actor, kill),
    receive {'DOWN', Mon, process, Actor, killed} -> ok after 5000 -> error(death_timeout) end,
    receive {'DOWN', CallerMon, process, Caller, _} -> ok
    after 5000 -> error(caller_timeout) end,
    %% The accepted coroutine may finish after actor death. This queued check
    %% establishes completion before collecting the context's BEAM heap.
    ref(Ctx, Env, <<"None">>),
    true = erlang:garbage_collect(Ctx),
    ok = py_context:exec(Ctx, <<"import gc; gc.collect()">>, Env),
    try check(Ctx, Env, <<"builtins._tracked_actor() is None">>, #{})
    after py_context:exec(Ctx, <<"del builtins._tracked_actor">>, Env) end.

interpreter_validation(Config) ->
    Ctx = context(Config),
    {ok, Other} = py_context:new(#{mode => owngil}),
    try
        ForeignEnv = env(Other),
        {error, local_objects_require_worker} = py_context:eval_ref(Other, <<"1">>, #{}, ForeignEnv),
        {error, env_wrong_interpreter} = py_context:eval_ref(Ctx, <<"1">>, #{}, ForeignEnv)
    after py_context:stop(Other) end,
    ok.

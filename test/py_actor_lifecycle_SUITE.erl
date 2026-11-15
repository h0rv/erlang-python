-module(py_actor_lifecycle_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([owned_kill/1, owned_inflight_kill/1, borrowed_kill/1,
         nested_retained_callback/1, method_validation/1, cancelled_call/1]).

all() -> [owned_kill, owned_inflight_kill, borrowed_kill,
          nested_retained_callback, method_validation, cancelled_call].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    Config.

end_per_suite(_Config) ->
    application:stop(erlang_python).

with_context(Fun) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    TestDir = filename:dirname(code:which(?MODULE)),
    try
        ok = py_context:exec(Ctx, iolist_to_binary(io_lib:format(
            "import sys; sys.path.insert(0, ~p)", [TestDir]))),
        Fun(Ctx)
    after py_context:destroy(Ctx) end.

portable(Ctx, Expression) ->
    {ok, Ref} = py_context:eval(Ctx,
        <<"__import__('erlang')._actor_retain(", Expression/binary, ")">>),
    Ref.

tracked(Ctx) ->
    Factory = portable(Ctx, <<"__import__('py_test_actor_lifecycle').Tracked">>),
    Method = portable(Ctx, <<"__import__('py_test_actor_lifecycle').Tracked.run">>),
    {Factory, Method}.

owned(Ctx) ->
    {Factory, Method} = tracked(Ctx),
    {ok, {ok, Actor}} = py_callback:execute(<<"_actor_spawn">>,
        [Factory, [Method], <<"unbounded">>]),
    #{ctx := Owned, owned := true} = sys:get_state(Actor),
    {Actor, Owned, Method}.

down(Pid, Mon) ->
    receive {'DOWN', Mon, process, Pid, _} -> ok
    after 5000 -> error(process_survived) end.

kill(Pid) ->
    Mon = monitor(process, Pid),
    exit(Pid, kill),
    down(Pid, Mon).

released(Ctx, Owned) ->
    false = is_process_alive(Owned),
    false = ets:member(py_context_refs, Owned),
    lists:foreach(fun erlang:garbage_collect/1, processes()),
    {ok, true} = py_context:call(Ctx, py_test_actor_lifecycle, collected, [], #{}),
    ok.

owned_kill(_Config) ->
    with_context(fun(Ctx) ->
        {Actor, Owned, _} = owned(Ctx),
        Mon = monitor(process, Owned),
        true = ets:member(py_context_refs, Owned),
        kill(Actor),
        down(Owned, Mon),
        released(Ctx, Owned)
    end).

owned_inflight_kill(_Config) ->
    with_gate(fun(Gate) ->
        with_context(fun(Ctx) ->
            {Actor, Owned, Method} = owned(Ctx),
            Mon = monitor(process, Owned),
            Args = portable(Ctx, <<"()">>),
            Kwargs = portable(Ctx, <<"{}">>),
            {Caller, CallerMon} = spawn_monitor(fun() ->
                py_object_actor:call(Actor, Method, Args, Kwargs, infinity)
            end),
            entered(Gate),
            kill(Actor),
            down(Caller, CallerMon),
            %% The Python coroutine is still awaiting the gate. Neither the
            %% registry nor the context can be torn down before it returns.
            true = is_process_alive(Owned),
            true = ets:member(py_context_refs, Owned),
            Gate ! release,
            down(Owned, Mon),
            released(Ctx, Owned)
        end)
    end).

borrowed_kill(_Config) ->
    with_context(fun(Ctx) ->
        {Factory, Method} = tracked(Ctx),
        {ok, Actor} = py_object_actor:start_link(Ctx, Factory, [Method], unbounded),
        unlink(Actor),
        kill(Actor),
        true = is_process_alive(Ctx),
        {ok, 42} = py_context:eval(Ctx, <<"42">>),
        {ok, Env} = py_context:create_local_env(Ctx),
        {ok, _} = py_context:eval_ref(Ctx, <<"object()">>, #{}, Env),
        ok
    end).

nested_retained_callback(_Config) ->
    with_context(fun(Ctx) ->
        {ok, Env} = py_context:create_local_env(Ctx),
        {ok, Func} = py_context:eval_ref(Ctx, <<"lambda: 42">>, #{}, Env),
        {ok, Args} = py_context:eval_ref(Ctx, <<"()">>, #{}, Env),
        {ok, Kwargs} = py_context:eval_ref(Ctx, <<"{}">>, #{}, Env),
        ok = py_callback:register(actor_lifecycle_nested, fun([]) ->
            {ok, Value} = py_context:apply_ref(Ctx, Func, Args, Kwargs, Env, 1000),
            {ok, _} = py_context:eval_ref(Ctx, <<"value + 1">>,
                                        #{<<"value">> => Value}, Env),
            {ok, 42} = py_context:eval(Ctx, <<"42">>, #{}, 1000, Env),
            {ok, 3} = py_context:call(Ctx, builtins, len, [[1, 2, 3]], #{}, 1000),
            ok = py_context:exec(Ctx, <<"legacy_nested = 7">>, Env),
            {ok, 7} = py_context:eval(Ctx, <<"legacy_nested">>, #{}, 1000, Env),
            42
        end),
        try
            {ok, Outer} = py_context:eval_ref(Ctx,
                <<"lambda: __import__('erlang').call('actor_lifecycle_nested')">>, #{}, Env),
            {ok, Result} = py_context:apply_ref(Ctx, Outer, Args, Kwargs, Env, 3000),
            {ok, _} = py_context:eval_ref(Ctx, <<"1 / (value == 42)">>,
                                        #{<<"value">> => Result}, Env)
        after py_callback:unregister(actor_lifecycle_nested) end
    end).

method_validation(_Config) ->
    with_context(fun(Ctx) ->
        {ok, true} = py_context:call(Ctx, py_test_actor_lifecycle, registration, [], #{})
    end).

cancelled_call(_Config) ->
    with_gate(fun(_Gate) ->
        with_context(fun(Ctx) ->
            {ok, true} = py_context:call(Ctx, py_test_actor_lifecycle, cancellation,
                                         [], #{}, 10000)
        end)
    end).

with_gate(Fun) ->
    Gate = spawn_link(fun() -> gate([], []) end),
    ok = py_callback:register(actor_lifecycle_gate, fun([]) ->
        Gate ! {enter, self()},
        receive release -> ok after 5000 -> error(gate_timeout) end
    end),
    ok = py_callback:register(actor_lifecycle_entered, fun([]) -> entered(Gate) end),
    ok = py_callback:register(actor_lifecycle_release, fun([]) -> Gate ! release, ok end),
    ok = py_callback:register(actor_lifecycle_collect, fun([]) ->
        lists:foreach(fun erlang:garbage_collect/1, processes()), ok
    end),
    try Fun(Gate)
    after
        Gate ! stop,
        [py_callback:unregister(Name) || Name <- [actor_lifecycle_gate,
            actor_lifecycle_entered, actor_lifecycle_release, actor_lifecycle_collect]]
    end.

entered(Gate) ->
    Gate ! {wait, self()},
    receive entered -> ok after 5000 -> error(entry_timeout) end.

gate(Running, Waiting) ->
    receive
        {enter, Pid} ->
            [W ! entered || W <- Waiting],
            gate([Pid | Running], []);
        {wait, Pid} when Running =/= [] ->
            Pid ! entered,
            gate(Running, Waiting);
        {wait, Pid} -> gate(Running, [Pid | Waiting]);
        release ->
            [P ! release || P <- Running],
            gate([], Waiting);
        stop -> [P ! release || P <- Running], ok
    end.

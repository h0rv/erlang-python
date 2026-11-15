-module(py_callback_lifetime_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([completed_future/1, actor_result/1, saturation/1, cancelled_future/1]).

all() -> [completed_future, actor_result, saturation, cancelled_future].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    Config.

end_per_suite(_Config) ->
    application:stop(erlang_python).

completed_future(_Config) ->
    ok = py:register_function(callback_lifetime_echo, fun([]) -> ok end),
    try
        {ok, true} = run(completed_future)
    after
        py:unregister_function(callback_lifetime_echo)
    end.

actor_result(_Config) ->
    ok = py:register_function(callback_lifetime_collect, fun([]) ->
        %% Resource terms on Erlang heaps also need collection. Python GC
        %% alone cannot release their native references to the result.
        lists:foreach(fun erlang:garbage_collect/1, processes()),
        ok
    end),
    try
        {ok, true} = run(actor_result)
    after
        py:unregister_function(callback_lifetime_collect)
    end.

saturation(_Config) ->
    Parent = self(),
    Gate = spawn_link(fun() -> gate(Parent, 10000, []) end),
    ok = py:register_function(callback_lifetime_hold, fun([]) -> hold(Gate) end),
    ok = py:register_function(callback_lifetime_echo, fun([]) -> ok end),
    ok = py:register_function(callback_lifetime_rejected, fun([]) ->
        Parent ! rejected_visible,
        ok
    end),
    {Runner, Monitor} = spawn_monitor(fun() -> Parent ! {result, run(saturation)} end),
    try
        receive saturated -> ok after 5000 -> ct:fail(not_saturated) end,
        receive rejected_visible -> ok after 5000 -> ct:fail(rejected_callbacks_hung) end,
        Gate ! release,
        receive {result, {ok, {10000, 3}}} -> ok
        after 5000 -> ct:fail(accepted_callbacks_hung) end,
        receive {'DOWN', Monitor, process, Runner, normal} -> ok
        after 5000 -> ct:fail(runner_hung) end
    after
        Gate ! stop,
        py:unregister_function(callback_lifetime_hold),
        py:unregister_function(callback_lifetime_echo),
        py:unregister_function(callback_lifetime_rejected)
    end.

cancelled_future(_Config) ->
    Parent = self(),
    Gate = spawn_link(fun() -> gate(Parent, 1, []) end),
    ok = py:register_function(callback_lifetime_cancel, fun([]) -> hold(Gate) end),
    ok = py:register_function(callback_lifetime_cancel_release, fun([]) ->
        Gate ! release,
        ok
    end),
    try
        {ok, true} = run(cancelled_future)
    after
        Gate ! stop,
        py:unregister_function(callback_lifetime_cancel),
        py:unregister_function(callback_lifetime_cancel_release)
    end.

hold(Gate) ->
    Gate ! {entered, self()},
    receive release -> ok after 5000 -> error(barrier_timeout) end.

gate(Parent, Remaining, Waiting) ->
    receive
        {entered, Pid} when Remaining =:= 1 ->
            Parent ! saturated,
            gate(Parent, 0, [Pid | Waiting]);
        {entered, Pid} ->
            gate(Parent, Remaining - 1, [Pid | Waiting]);
        release ->
            [Pid ! release || Pid <- Waiting],
            open_gate();
        stop ->
            [Pid ! release || Pid <- Waiting],
            ok
    end.

open_gate() ->
    receive
        {entered, Pid} -> Pid ! release, open_gate();
        stop -> ok
    end.

run(Case) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    TestDir = filename:dirname(code:which(?MODULE)),
    try
        ok = py_context:exec(Ctx, iolist_to_binary(io_lib:format(
            "import sys; sys.path.insert(0, ~p)", [TestDir]))),
        py_context:call(Ctx, py_test_callback_lifetime, run,
                        [atom_to_binary(Case)], #{}, 5000)
    after
        py_context:destroy(Ctx)
    end.

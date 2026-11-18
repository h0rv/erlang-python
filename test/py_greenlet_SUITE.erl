-module(py_greenlet_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1,
         roundtrip/1, empty/1, error_recovery/1, pooled_roundtrip/1,
         pooled_empty/1, pooled_error_recovery/1, pooled_shutdown/1]).

all() -> [roundtrip, empty, error_recovery, pooled_roundtrip,
          pooled_empty, pooled_error_recovery, pooled_shutdown].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    {ok, Context} = py_context:new(#{mode => worker}),
    case py_context:eval(Context,
            <<"__import__('importlib.util').util.find_spec('greenlet') is not None">>) of
        {ok, true} ->
            Dir = filename:dirname(code:which(?MODULE)),
            Code = iolist_to_binary(io_lib:format(
                "import sys; sys.path.insert(0, ~p); import py_test_greenlet", [Dir])),
            ok = py_context:exec(Context, Code),
            Online = erlang:system_flag(dirty_cpu_schedulers_online, 1),
            [{context, Context}, {dirty_online, Online} | Config];
        {ok, false} ->
            ok = py_context:stop(Context),
            {skip, "greenlet is not installed"}
    end.

end_per_suite(Config) ->
    erlang:system_flag(dirty_cpu_schedulers_online, ?config(dirty_online, Config)),
    ok = py_context:stop(?config(context, Config)),
    application:stop(erlang_python).

roundtrip(_) -> check_roundtrip(<<"value">>).
empty(_) -> check_roundtrip(<<>>).

check_roundtrip(Value) ->
    with_loop(fun(Loop) ->
        {ok, Value} = run(Loop, begin_switch, [Value]),
        ok = py_nif:process_ready_tasks(Loop),
        {ok, <<"resumed">>} = run(Loop, finish_switch, []),
        {ok, true} = run(Loop, thread_state_preserved, [])
    end).

error_recovery(_) ->
    with_loop(fun(Loop) ->
        {ok, <<"value">>} = run(Loop, begin_switch, [<<"value">>]),
        {error, {'ValueError', "greenlet failure"}} = run(Loop, fail_switch, []),
        {ok, true} = run(Loop, thread_state_preserved, []),
        {ok, <<"resumed">>} = run(Loop, finish_switch, [])
    end).

pooled_roundtrip(Config) ->
    erlang:system_flag(dirty_cpu_schedulers_online, ?config(dirty_online, Config)),
    Refs = [py_event_loop_pool:create_task(py_test_greenlet, pooled_switch, [<<"value">>])
            || _ <- lists:seq(1, 32)],
    [{ok, <<"value">>} = py_event_loop_pool:await(Ref, 5000) || Ref <- Refs],
    ok.

pooled_empty(_) ->
    {ok, <<>>} = py_event_loop_pool:run(py_test_greenlet, pooled_switch, [<<>>]),
    ok.

pooled_error_recovery(_) ->
    {error, <<"ValueError: greenlet failure", _/binary>>} =
        py_event_loop_pool:run(py_test_greenlet, pooled_failure, []),
    {ok, <<"value">>} = py_event_loop_pool:run(py_test_greenlet, pooled_switch, [<<"value">>]),
    ok.

pooled_shutdown(_) ->
    {links, Links} = process_info(whereis(py_event_loop_pool), links),
    Supervisor = whereis(erlang_python_sup),
    Monitors = [monitor(process, Pid) || Pid <- Links, Pid =/= Supervisor],
    ok = supervisor:terminate_child(erlang_python_sup, py_event_loop_pool),
    try
        lists:foreach(fun(Monitor) ->
            receive {'DOWN', Monitor, process, _, _} -> ok
            after 5000 -> ct:fail(driver_not_stopped)
            end
        end, Monitors)
    after
        {ok, _} = supervisor:restart_child(erlang_python_sup, py_event_loop_pool)
    end,
    pooled_empty([]).

with_loop(Fun) ->
    {ok, Loop} = py_nif:event_loop_new(),
    try Fun(Loop)
    after
        py_nif:event_loop_release_python_loop(Loop),
        py_nif:event_loop_destroy(Loop)
    end.

run(Loop, Function, Args) ->
    Ref = make_ref(),
    ok = py_nif:submit_task(Loop, self(), Ref, <<"py_test_greenlet">>,
                           atom_to_binary(Function), Args, #{}),
    ok = py_nif:process_ready_tasks(Loop),
    py_event_loop:await(Ref, 5000).

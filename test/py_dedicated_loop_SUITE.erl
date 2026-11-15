-module(py_dedicated_loop_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1,
         dedicated_contexts/1, shared_guard_is_preserved/1, unsupported_mode/1,
         worker_failure_keeps_loop_identity/1]).

all() -> [dedicated_contexts, shared_guard_is_preserved, unsupported_mode,
          worker_failure_keeps_loop_identity].
init_per_suite(Config) ->
    {ok,_} = application:ensure_all_started(erlang_python),
    [{test_dir,filename:dirname(code:which(?MODULE))}|Config].
end_per_suite(_) -> application:stop(erlang_python).

dedicated_contexts(Config) ->
    Before = live(),
    A = context(Config, dedicated),
    B = context(Config, dedicated),
    {ok,ALoop} = py_context:loop_ref(A),
    {ok,BLoop} = py_context:loop_ref(B),
    false = ALoop =:= BLoop,
    {ok,AId} = run(A, remember, [<<"a">>]),
    {ok,BId} = run(B, remember, [<<"b">>]),
    false = AId =:= BId,
    {ok,true} = run(A, different, [<<"b">>]),
    {ok,true} = run(B, different, [<<"a">>]),
    {ok,ALoop} = run(A, echo, [ALoop]),
    {ok,BLoop} = run(B, echo, [BLoop]),
    stop_loop(A),
    {ok,true} = py_context:call(A, py_test_dedicated_loop, closed, [<<"a">>]),
    {ok,true} = run(B, different, [<<"a">>]),
    ok = py_context:start_loop(A),
    {ok,_} = run(A, remember, [<<"a-restarted">>]),
    stop_loop(A), stop_loop(B),
    {ok,true} = py_context:call(B, py_test_dedicated_loop, closed, [<<"b">>]),
    ok = py_context:stop(A), ok = py_context:stop(B),
    Before = live().

shared_guard_is_preserved(Config) ->
    A = context(Config, shared),
    {ok,B} = py_context:new(#{mode=>worker}),
    {error,{'RuntimeError',_}} = py_context:start_loop(B),
    {ok,_} = run(A, remember, [<<"shared-still-running">>]),
    stop_loop(A), ok = py_context:stop(A), ok = py_context:stop(B).

worker_failure_keeps_loop_identity(Config) ->
    A = context(Config, dedicated),
    {ok,Owned} = py_context:loop_ref(A),
    {links,Links} = process_info(A, links),
    [Worker] = Links -- [self()],
    Mon = monitor(process, Worker),
    exit(Worker, kill),
    receive {'DOWN',Mon,process,Worker,killed} -> ok
    after 2000 -> ct:fail(worker_did_not_exit) end,
    {ok,Owned} = py_context:loop_ref(A),
    {error,timeout} = py_context:stop_loop(A,20),
    receive {py_loop_exit,A,Early} -> ct:fail({false_ack,Early}) after 0 -> ok end,
    {ok,Replacement} = py_event_worker:start_link(<<"test_repair">>,Owned),
    ok = py_nif:event_loop_set_worker(Owned,Replacement),
    Replacement ! task_ready,
    receive {py_loop_exit,A,{ok,<<"stopped">>}} -> ok
    after 5000 -> ct:fail(repaired_loop_did_not_stop) end,
    ok = py_event_worker:stop(Replacement), ok = py_context:stop(A).

unsupported_mode(_Config) ->
    Before = live(),
    {error,{unsupported_managed_loop,owngil}} = py_context:new(#{mode=>owngil,managed_loop=>dedicated}),
    {error,{unsupported_managed_loop,isolated}} = py_context:new(#{mode=>isolated,managed_loop=>dedicated}),
    {error,{invalid_managed_loop,true}} = py_context:new(#{managed_loop=>true}),
    Before = live().

context(Config, Kind) ->
    {ok,C} = py_context:new(#{mode=>worker,managed_loop=>Kind}),
    Code = iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p); import py_test_dedicated_loop", [?config(test_dir,Config)])),
    ok = py_context:exec(C,Code), ok = py_context:start_loop(C), C.
run(C,F,A) -> py_context:submit_await(C,py_test_dedicated_loop,F,A,#{},5000).
stop_loop(C) ->
    ok = py_context:stop_loop(C,1000),
    receive {py_loop_exit,C,{ok,<<"stopped">>}} -> ok
    after 2000 -> ct:fail(missing_clean_ack) end.
live() ->
    M = py_nif:get_debug_counters(),
    maps:get(ctx_created,M)-maps:get(ctx_destroyed,M).

%% Runtime regressions for Python-only wakeups. No Python timers, FDs or
%% additional task submissions may drive a pending test to completion.
-module(py_threadsafe_wakeup_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([threadsafe_result/1, executor_result/1, to_thread_result/1,
         burst_result/1, ready_chain_result/1, independent_loop_result/1,
         shutdown_wakeup_result/1]).

all() ->
    [threadsafe_result, executor_result, to_thread_result, burst_result,
     ready_chain_result, independent_loop_result, shutdown_wakeup_result].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    TestDir = filename:dirname(proplists:get_value(source, ?MODULE:module_info(compile))),
    ok = py:exec(iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [filename:absname(TestDir)]))),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erlang_python).

threadsafe_result(_Config) ->
    check_both_drivers(threadsafe_result, 42).

executor_result(_Config) ->
    check_both_drivers(executor_result, 210).

to_thread_result(_Config) ->
    check_both_drivers(to_thread_result, 42).

burst_result(_Config) ->
    check_both_drivers(burst_result, 2000).

ready_chain_result(_Config) ->
    check_both_drivers(ready_chain_result, 350).

independent_loop_result(_Config) ->
    {ok, 42} = py:call(py_test_threadsafe_wakeup, independent_loop_result, []).

shutdown_wakeup_result(_Config) ->
    {ok, true} = py:call(py_test_threadsafe_wakeup, shutdown_wakeup_result, []).

check_both_drivers(Function, Expected) ->
    %% Await only receives the result. Its Erlang timeout cannot wake Python.
    %% Finish each probe before submitting the next one.
    Ref = py_event_loop:create_task(py_test_threadsafe_wakeup, Function, []),
    {ok, Expected} = py_event_loop:await(Ref, 2000),
    PoolRef = py_event_loop_pool:create_task(py_test_threadsafe_wakeup, Function, []),
    {ok, Expected} = py_event_loop_pool:await(PoolRef, 2000),
    ok.

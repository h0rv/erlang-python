-module(py_managed_shutdown_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2,
         end_per_group/2]).
-export([owners_quiesce_before_ack/1, timeout_retains_live_work/1,
         cleanup_failure_is_not_success/1, restart_churn/1, other_loop_untouched/1,
         completed_successors_are_observed/1, bounded_successor_churn/1]).

all() -> [{group, worker}, {group, owngil}].
groups() ->
    Cases = [owners_quiesce_before_ack, timeout_retains_live_work,
             cleanup_failure_is_not_success, restart_churn,
             completed_successors_are_observed, bounded_successor_churn],
    [{worker, [], Cases}, {owngil, [], Cases ++ [other_loop_untouched]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    [{test_dir, filename:dirname(code:which(?MODULE))} | Config].
end_per_suite(_Config) -> application:stop(erlang_python).
init_per_group(worker, Config) -> [{mode, worker} | Config];
init_per_group(owngil, Config) ->
    case py_nif:owngil_supported() of
        true -> [{mode, owngil} | Config];
        false -> {skip, "Requires Python 3.14 OWN_GIL support"}
    end.
end_per_group(_, _) -> ok.

owners_quiesce_before_ack(Config) ->
    C = context(Config),
    ok = py_context:start_loop(C),
    {ok, <<"prepared">>} = submit(C, setup, []),
    ok = py_context:stop_loop(C, 1000),
    normal_exit(C),
    {ok, true} = py_context:eval(C, <<"py_test_managed_shutdown.assert_clean()">>),
    ok = py_context:stop(C).

timeout_retains_live_work(Config) ->
    C = context(Config),
    ok = py_context:start_loop(C),
    {ok, <<"prepared">>} = submit(C, setup_resistant, [self()]),
    Parent = self(),
    {Stopper, Monitor} = spawn_monitor(fun() ->
        Parent ! {long_stop, py_context:stop_loop(C, 5000)}
    end),
    receive <<"cancellation-seen">> -> ok
    after 2000 -> ct:fail(cancellation_not_delivered)
    end,
    {error, timeout} = py_context:stop_loop(C, 20),
    receive {py_loop_exit, C, Early} -> ct:fail({premature_exit, Early})
    after 0 -> ok
    end,
    {ok, true} = submit(C, assert_retained, []),
    {ok, <<"released">>} = submit(C, release, []),
    receive {long_stop, ok} -> ok
    after 5000 -> ct:fail(clean_stop_not_acknowledged)
    end,
    receive {'DOWN', Monitor, process, Stopper, normal} -> ok
    after 1000 -> ct:fail(stopper_leaked)
    end,
    normal_exit(C),
    {ok, true} = py_context:eval(C, <<"py_test_managed_shutdown.assert_released()">>),
    ok = py_context:stop(C).

cleanup_failure_is_not_success(Config) ->
    C = context(Config),
    ok = py_context:start_loop(C),
    {ok, <<"prepared">>} = submit(C, setup_failed_cleanup, []),
    {error, {loop_exit, {error, _}}} = py_context:stop_loop(C, 1000),
    receive {py_loop_exit, C, {error, _}} -> ok
    after 2000 -> ct:fail(missing_failed_exit)
    end,
    {ok, true} = py_context:eval(C, <<"py_test_managed_shutdown.assert_clean()">>),
    ok = py_context:stop(C).

restart_churn(Config) ->
    C = context(Config),
    [begin
        ok = py_context:start_loop(C),
        {ok, <<"prepared">>} = submit(C, setup, []),
        ok = py_context:stop_loop(C, 1000),
        normal_exit(C),
        {ok, true} = py_context:eval(C, <<"py_test_managed_shutdown.assert_clean()">>)
    end || _ <- lists:seq(1, 20)],
    ok = py_context:stop(C).

other_loop_untouched(Config) ->
    A = context(Config),
    B = context(Config),
    ok = py_context:start_loop(A),
    ok = py_context:start_loop(B),
    {ok, <<"prepared">>} = submit(A, setup, []),
    {ok, <<"prepared">>} = submit(B, setup, []),
    ok = py_context:stop_loop(A, 1000),
    normal_exit(A),
    {ok, true} = py_context:eval(A, <<"py_test_managed_shutdown.assert_clean()">>),
    {ok, true} = submit(B, assert_running, []),
    ok = py_context:stop_loop(B, 1000),
    normal_exit(B),
    {ok, true} = py_context:eval(B, <<"py_test_managed_shutdown.assert_clean()">>),
    ok = py_context:stop(A),
    ok = py_context:stop(B).

completed_successors_are_observed(Config) ->
    C = context(Config),
    [begin
        ok = py_context:start_loop(C),
        {ok, <<"prepared">>} = submit(C, setup_successors, [Timing, Fail, Eager, Nested, Factory]),
        verify_stop(py_context:stop_loop(C, 1000), Fail),
        verify_exit(C, Fail),
        {ok, true} = py_context:eval(C, <<"py_test_managed_shutdown.assert_successors()">>)
    end || Timing <- [<<"before_scan">>, <<"during_wait">>, <<"final_turn">>],
           Fail <- [false, true], Eager <- [false, true], Nested <- [false, true],
           Factory <- [false, true]],
    ok = py_context:stop(C).

bounded_successor_churn(Config) ->
    C = context(Config),
    [begin
        ok = py_context:start_loop(C),
        {ok, <<"prepared">>} = submit(C, setup_runaway, [self(), Fail]),
        Parent = self(),
        {Stopper, Monitor} = spawn_monitor(fun() ->
            Parent ! {runaway_stop, py_context:stop_loop(C, 5000)}
        end),
        receive <<"runaway-gated">> -> ok
        after 2000 -> ct:fail(runaway_did_not_reach_gate)
        end,
        {error, timeout} = py_context:stop_loop(C, 20),
        receive {py_loop_exit, C, Early} -> ct:fail({premature_exit, Early})
        after 0 -> ok
        end,
        {ok, true} = submit(C, assert_runaway_retained, []),
        {ok, <<"released">>} = submit(C, release_runaway, []),
        receive {runaway_stop, Stop} -> verify_stop(Stop, Fail)
        after 5000 -> ct:fail(runaway_stop_not_acknowledged)
        end,
        receive {'DOWN', Monitor, process, Stopper, normal} -> ok
        after 1000 -> ct:fail(stopper_leaked)
        end,
        verify_exit(C, Fail),
        {ok, true} = py_context:eval(C, <<"py_test_managed_shutdown.assert_runaway_done()">>)
    end || Fail <- [false, true]],
    ok = py_context:stop(C).

verify_stop(ok, false) -> ok;
verify_stop({error, _} = Error, true) -> sanitized(Error);
verify_stop(Other, Fail) -> ct:fail({wrong_stop, Fail, Other}).

verify_exit(C, false) -> normal_exit(C);
verify_exit(C, true) ->
    receive {py_loop_exit, C, {error, _} = Error} -> sanitized(Error)
    after 2000 -> ct:fail(missing_failed_exit)
    end.

sanitized(Error) ->
    nomatch = binary:match(term_to_binary(Error), <<"sensitive cleanup payload">>),
    ok.

context(Config) ->
    {ok, C} = py_context:new(#{mode => ?config(mode, Config)}),
    Code = iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p); import py_test_managed_shutdown",
        [?config(test_dir, Config)])),
    ok = py_context:exec(C, Code),
    C.

submit(C, Function, Args) ->
    py_context:submit_await(C, py_test_managed_shutdown, Function, Args, #{}, 5000).

normal_exit(C) ->
    receive {py_loop_exit, C, {ok, <<"stopped">>}} -> ok
    after 2000 -> ct:fail(missing_normal_exit)
    end.

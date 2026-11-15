-module(py_work_admission_SUITE).

-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    unconfigured_fails_closed/1, shared_count_and_reuse/1, encoded_bytes/1,
    running_survives_reply_timeout/1, caller_death/1, cancellation_cleanup/1,
    cancellation_before_start/1, destination_death_during_native_work/1,
    start_failure_releases/1, close_retains_queued_work/1, legacy_unchanged/1,
    shared_bytes_across_callers/1, submitter_death_race/1, worker_death/1,
    exceptions_complete/1, unsupported_mode_fails_closed/1, custom_factory_fails_closed/1,
    configuration_shutdown_race/1, concurrent_completion_and_admission/1,
    uncertain_constructor_fails_closed/1
]).

all() -> [unconfigured_fails_closed, shared_count_and_reuse, encoded_bytes,
          running_survives_reply_timeout, caller_death, cancellation_cleanup,
          cancellation_before_start, destination_death_during_native_work,
          start_failure_releases, close_retains_queued_work, legacy_unchanged,
          shared_bytes_across_callers, submitter_death_race, worker_death,
          exceptions_complete, unsupported_mode_fails_closed, custom_factory_fails_closed,
          configuration_shutdown_race, concurrent_completion_and_admission,
          uncertain_constructor_fails_closed].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    TestDir = filename:dirname(code:which(?MODULE)),
    ok = py:exec("import sys; sys.path.insert(0, '" ++ TestDir ++ "')"),
    Config.

end_per_suite(_Config) -> application:stop(erlang_python).

unconfigured_fails_closed(_Config) ->
    with_loop(fun(L) ->
        {error, admission_not_configured} = submit(L),
        {error, admission_not_configured} = py_nif:work_admission_info(L),
        ok = py_nif:work_admission_configure(L, self(), 1, 10000),
        {error, already_configured} = py_nif:work_admission_configure(L, self(), 2, 20000),
        try py_nif:work_admission_configure(L, self(), 0, 1) of
            _ -> ct:fail(accepted_invalid_limit)
        catch error:badarg -> ok
        end,
        ok
    end).

shared_count_and_reuse(_Config) ->
    with_loop(fun(L) ->
        ok = py_nif:work_admission_configure(L, self(), 3, 10000),
        Parent = self(),
        %% Every process receives an alias of the same native resource. No
        %% worker drains the queue until all producers finish admission.
        [spawn(fun() -> Parent ! {admitted, submit(L)} end) || _ <- lists:seq(1, 40)],
        Results = [receive {admitted, Result} -> Result after 5000 -> ct:fail(producer_timeout) end
                   || _ <- lists:seq(1, 40)],
        3 = length([ok || ok <- Results]),
        37 = length([full || {error, overloaded} <- Results]),
        #{count := 3, bytes := Bytes} = py_nif:work_admission_info(L),
        true = Bytes =< 10000,
        ok = py_nif:process_ready_tasks(L),
        await_count(L, 0),
        ok = submit(L),
        #{count := 1} = py_nif:work_admission_info(L),
        ok = py_nif:process_ready_tasks(L),
        await_count(L, 0)
    end).

encoded_bytes(_Config) ->
    with_loop(fun(L) ->
        Ref = make_ref(),
        Payload = binary:copy(<<7>>, 2048),
        Request = {self(), Ref, <<"builtins">>, <<"len">>, [Payload], #{}, 1},
        Size = byte_size(term_to_binary(Request)),
        ok = py_nif:work_admission_configure(L, self(), 10, Size),
        ok = py_nif:submit_task_bounded(L, self(), Ref, <<"builtins">>, <<"len">>, [Payload], #{}),
        #{count := 1, bytes := Size} = py_nif:work_admission_info(L),
        {error, overloaded} = py_nif:submit_task_bounded(
            L, self(), make_ref(), <<"builtins">>, <<"len">>, [Payload], #{}),
        #{count := 1, bytes := Size} = py_nif:work_admission_info(L),
        ok = py_nif:process_ready_tasks(L),
        receive {async_result, Ref, {ok, 2048}} -> ok after 5000 -> ct:fail(no_result) end,
        await_count(L, 0),
        %% An individual oversized request also leaves no reservation behind.
        {error, overloaded} = py_nif:submit_task_bounded(
            L, self(), make_ref(), <<"builtins">>, <<"len">>, [<<Payload/binary, 8>>], #{}),
        #{count := 0, bytes := 0} = py_nif:work_admission_info(L)
    end).

running_survives_reply_timeout(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        Ref = bounded(L, hold, [reply_timeout]),
        start_worker(L),
        await_entered(L, reply_timeout),
        {error, timeout} = py_event_loop:await(Ref, 0),
        #{count := 1, bytes := Bytes} = py_nif:work_admission_info(L),
        true = Bytes > 0,
        {error, overloaded} = submit(L),
        {ok, none} = control(L, release, [reply_timeout]),
        receive {async_result, Ref, {ok, _}} -> ok after 5000 -> ct:fail(no_result) end,
        await_count(L, 0),
        ok = submit(L),
        await_count(L, 0)
    end).

caller_death(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        Parent = self(),
        Pid = spawn(fun() ->
            Ref = bounded(L, hold, [dead_caller]),
            Parent ! {submitted, Ref},
            receive stop -> ok end
        end),
        receive {submitted, _} -> ok after 5000 -> ct:fail(no_submit) end,
        start_worker(L),
        await_entered(L, dead_caller),
        Monitor = monitor(process, Pid),
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok after 5000 -> ct:fail(no_down) end,
        #{count := 1} = py_nif:work_admission_info(L),
        {error, overloaded} = submit(L),
        {ok, none} = control(L, release, [dead_caller]),
        await_count(L, 0)
    end).

cancellation_cleanup(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        _ = bounded(L, hold, [cancel_cleanup]),
        start_worker(L),
        await_entered(L, cancel_cleanup),
        {ok, true} = control(L, cancel, [cancel_cleanup]),
        await_predicate(fun() -> control(L, cancelled, [cancel_cleanup]) =:= {ok, true} end),
        #{count := 1} = py_nif:work_admission_info(L),
        {error, overloaded} = submit(L),
        {ok, none} = control(L, release, [cancel_cleanup]),
        await_count(L, 0)
    end).

cancellation_before_start(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        _ = bounded(L, hold, [never_started]),
        Ref = make_ref(),
        %% Synchronous control runs in the same native drain batch before the
        %% newly scheduled coroutine gets its first Python step.
        ok = py_nif:submit_task(L, self(), Ref, <<"py_test_admission">>,
                              <<"cancel_before_start">>, [], #{}),
        ok = py_nif:process_ready_tasks(L),
        await_count(L, 0)
    end).

destination_death_during_native_work(Config) ->
    with_loop(fun(L) ->
        Owner = spawn(fun() -> receive stop -> ok end end),
        ok = py_nif:work_admission_configure(L, Owner, 1, 10000),
        Dir = ?config(priv_dir, Config),
        Started = filename:join(Dir, "native-started"),
        Stopped = filename:join(Dir, "native-stopped"),
        Ref = bounded(L, block, [list_to_binary(Started), list_to_binary(Stopped)]),
        start_worker(L),
        await_predicate(fun() -> filelib:is_file(Started) end),
        exit(Owner, kill),
        await_predicate(fun() ->
            #{closed := Closed} = py_nif:work_admission_info(L), Closed
        end),
        #{count := 1} = py_nif:work_admission_info(L),
        {error, admission_closed} = submit(L),
        %% Shutdown is also NOT evidence that this native/Python call ended.
        ok = py_nif:event_loop_destroy(L),
        #{count := 1} = py_nif:work_admission_info(L),
        ok = file:write_file(Stopped, <<"stop">>),
        receive {async_result, Ref, {ok, <<"stopped">>}} -> ok
        after 5000 -> ct:fail(native_did_not_end) end,
        await_count(L, 0),
        #{closed := true} = py_nif:work_admission_info(L)
    end).

start_failure_releases(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        Ref = make_ref(),
        ok = py_nif:submit_task_bounded(L, self(), Ref, <<"no_such_admission_module">>,
                                      <<"missing">>, [], #{}),
        ok = py_nif:process_ready_tasks(L),
        receive {async_result, Ref, {error, _}} -> ok after 5000 -> ct:fail(no_error) end,
        await_count(L, 0),
        ok = submit(L),
        ok = py_nif:process_ready_tasks(L),
        await_count(L, 0)
    end).

close_retains_queued_work(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        ok = submit(L),
        ok = py_nif:work_admission_close(L),
        ok = py_nif:work_admission_close(L),
        #{count := 1, closed := true} = py_nif:work_admission_info(L),
        {error, admission_closed} = submit(L),
        ok = py_nif:process_ready_tasks(L),
        await_count(L, 0),
        {error, admission_closed} = submit(L),
        {error, already_configured} = py_nif:work_admission_configure(L, self(), 1, 10000)
    end).

legacy_unchanged(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        ok = submit(L),
        %% The trusted legacy entrypoint intentionally bypasses the new gate.
        ok = py_nif:submit_task(L, self(), make_ref(), <<"builtins">>, <<"len">>, [<<>>], #{}),
        #{count := 1} = py_nif:work_admission_info(L),
        ok = py_nif:process_ready_tasks(L),
        await_count(L, 0)
    end).

uncertain_constructor_fails_closed(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        start_worker(L),
        {ok, none} = control(L, fail_constructor, []),
        try
            Ref = bounded(L, hold, [unknown_constructor]),
            receive {async_result, Ref, {error, _}} -> ok
            after 5000 -> ct:fail(no_constructor_failure) end,
            await_predicate(fun() ->
                #{closed := Closed} = py_nif:work_admission_info(L), Closed
            end),
            #{count := 1, bytes := Bytes} = py_nif:work_admission_info(L),
            true = Bytes > 0,
            {error, admission_closed} = submit(L),
            {ok, false} = control(L, entered, [unknown_constructor])
        after
            {ok, none} = control(L, restore_constructor, [])
        end
    end).

concurrent_completion_and_admission(_Config) ->
    with_loop(fun(L) ->
        ok = py_nif:work_admission_configure(L, self(), 3, 500),
        start_worker(L),
        Parent = self(),
        [spawn(fun() -> Parent ! {producer_done, run_producer(L, 100, 0)} end)
         || _ <- lists:seq(1, 12)],
        Accepted = collect_producers(L, 12, 0),
        true = Accepted > 0,
        await_count(L, 0)
    end).

run_producer(_L, 0, Accepted) -> Accepted;
run_producer(L, Remaining, Accepted) ->
    Ref = make_ref(),
    case py_nif:submit_task_bounded(L, self(), Ref, <<"builtins">>, <<"len">>, [<<>>], #{}) of
        ok ->
            {ok, 0} = py_event_loop:await(Ref, 5000),
            run_producer(L, Remaining - 1, Accepted + 1);
        {error, overloaded} ->
            %% This is a new test invocation, not retry of the rejected work.
            run_producer(L, Remaining - 1, Accepted)
    end.

collect_producers(_L, 0, Accepted) -> Accepted;
collect_producers(L, Remaining, Accepted) ->
    #{count := Count, bytes := Bytes} = py_nif:work_admission_info(L),
    true = Count =< 3,
    true = Bytes =< 500,
    receive {producer_done, N} -> collect_producers(L, Remaining - 1, Accepted + N)
    after 5000 -> ct:fail(producers_did_not_complete)
    end.

configuration_shutdown_race(_Config) ->
    lists:foreach(fun(_) ->
        with_loop(fun(L) ->
            Parent = self(),
            spawn(fun() ->
                Parent ! {configured, py_nif:work_admission_configure(L, Parent, 1, 10000)}
            end),
            spawn(fun() -> Parent ! {destroyed, py_nif:event_loop_destroy(L)} end),
            receive
                {configured, ok} -> ok;
                {configured, {error, admission_closed}} -> ok
            after 5000 -> ct:fail(no_configuration_result) end,
            receive {destroyed, ok} -> ok after 5000 -> ct:fail(no_shutdown_result) end,
            case submit(L) of
                {error, admission_closed} -> ok;
                {error, admission_not_configured} -> ok;
                Other -> ct:fail({accepted_after_shutdown, Other})
            end
        end)
    end, lists:seq(1, 40)).

shared_bytes_across_callers(_Config) ->
    with_loop(fun(L) ->
        Ref = make_ref(),
        Size = byte_size(term_to_binary({self(), Ref, <<"builtins">>, <<"len">>, [<<>>], #{}, 1})),
        ok = py_nif:work_admission_configure(L, self(), 40, 3 * Size),
        Parent = self(),
        [spawn(fun() -> Parent ! {admitted, submit(L)} end) || _ <- lists:seq(1, 40)],
        Results = [receive {admitted, Result} -> Result after 5000 -> ct:fail(producer_timeout) end
                   || _ <- lists:seq(1, 40)],
        3 = length([ok || ok <- Results]),
        37 = length([full || {error, overloaded} <- Results]),
        #{count := 3, bytes := Used} = py_nif:work_admission_info(L),
        Used = 3 * Size,
        ok = py_nif:process_ready_tasks(L),
        await_count(L, 0)
    end).

submitter_death_race(_Config) ->
    with_loop(fun(L) ->
        ok = py_nif:work_admission_configure(L, self(), 4, 10000),
        Parent = self(),
        lists:foreach(fun(_) ->
            Processes = [spawn_monitor(fun() ->
                Parent ! {starting, self()},
                submit(L),
                receive stop -> ok end
            end) || _ <- lists:seq(1, 40)],
            lists:foreach(fun(_) ->
                receive {starting, Pid} -> exit(Pid, kill)
                after 5000 -> ct:fail(no_starting_caller) end
            end, Processes),
            lists:foreach(fun({Pid, Mon}) ->
                receive {'DOWN', Mon, process, Pid, _} -> ok
                after 5000 -> ct:fail(no_down) end
            end, Processes),
            #{count := Count, bytes := Bytes} = py_nif:work_admission_info(L),
            true = Count =< 4,
            true = Bytes =< 10000,
            ok = py_nif:process_ready_tasks(L),
            await_count(L, 0)
        end, lists:seq(1, 10))
    end).

worker_death(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        start_worker(L),
        Worker = get(admission_worker),
        unlink(Worker),
        Mon = monitor(process, Worker),
        exit(Worker, kill),
        receive {'DOWN', Mon, process, Worker, _} -> ok
        after 5000 -> ct:fail(no_worker_down) end,
        {error, admission_closed} = submit(L),
        #{count := 0, closed := true} = py_nif:work_admission_info(L),
        erase(admission_worker)
    end).

exceptions_complete(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        start_worker(L),
        lists:foreach(fun(Func) ->
            Ref = bounded(L, Func, []),
            receive {async_result, Ref, {error, _}} -> ok
            after 5000 -> ct:fail(no_failure_result) end,
            await_count(L, 0)
        end, [fail_sync, fail_async])
    end).

custom_factory_fails_closed(_Config) ->
    with_loop(fun(L) ->
        configure(L),
        start_worker(L),
        {ok, none} = control(L, install_factory, []),
        Ref = bounded(L, hold, [custom_factory]),
        receive {async_result, Ref, {error, _}} -> ok
        after 5000 -> ct:fail(no_factory_failure) end,
        await_count(L, 0),
        {ok, false} = control(L, entered, [custom_factory]),
        {ok, none} = control(L, reset_factory, [])
    end).

unsupported_mode_fails_closed(_Config) ->
    case py_nif:owngil_supported() of
        false -> {skip, "OWN_GIL is unavailable"};
        true ->
            {ok, Context} = py_context:new(#{mode => owngil}),
            try
                {ok, Loop} = py_context:loop_ref(Context),
                {error, unsupported_admission_mode} =
                    py_nif:work_admission_configure(Loop, self(), 1, 10000),
                {error, admission_not_configured} = submit(Loop)
            after py_context:stop(Context)
            end
    end.

configure(L) -> py_nif:work_admission_configure(L, self(), 1, 10000).

submit(L) ->
    py_nif:submit_task_bounded(L, self(), make_ref(), <<"builtins">>, <<"len">>, [<<>>], #{}).

bounded(L, Func, Args) ->
    Ref = make_ref(),
    ok = py_nif:submit_task_bounded(L, self(), Ref, <<"py_test_admission">>,
                                  atom_to_binary(Func), Args, #{}),
    Ref.

control(L, Func, Args) ->
    Ref = make_ref(),
    ok = py_nif:submit_task(L, self(), Ref, <<"py_test_admission">>,
                          atom_to_binary(Func), Args, #{}),
    py_event_loop:await(Ref, 5000).

await_entered(L, Name) ->
    await_predicate(fun() -> control(L, entered, [Name]) =:= {ok, true} end).

await_count(L, Count) ->
    await_predicate(fun() ->
        #{count := Current, bytes := Bytes} = py_nif:work_admission_info(L),
        Current =:= Count andalso (Count =/= 0 orelse Bytes =:= 0)
    end).

await_predicate(Fun) -> await_predicate(Fun, erlang:monotonic_time(millisecond) + 5000).
await_predicate(Fun, Deadline) ->
    case Fun() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(5), await_predicate(Fun, Deadline);
                false -> ct:fail(condition_timeout)
            end
    end.

start_worker(L) ->
    {ok, Worker} = py_event_worker:start_link(<<"admission-test">>, L),
    ok = py_nif:event_loop_set_worker(L, Worker),
    put(admission_worker, Worker),
    Worker ! task_ready,
    ok.

with_loop(Fun) ->
    {ok, L} = py_nif:event_loop_new(),
    try Fun(L)
    after
        py_nif:work_admission_close(L),
        case erase(admission_worker) of
            undefined -> ok;
            Worker -> py_event_worker:stop(Worker)
        end,
        py_nif:event_loop_release_python_loop(L),
        py_nif:event_loop_destroy(L)
    end.

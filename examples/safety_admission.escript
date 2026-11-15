#!/usr/bin/env escript
-mode(compile).

main(Args) ->
    Root = filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    Profile = case Args of [] -> "default"; ["test"] -> "test" end,
    true = code:add_patha(filename:join([Root, "_build", Profile, "lib", "erlang_python", "ebin"])),
    {ok, _} = application:ensure_all_started(erlang_python),
    Examples = filename:join(Root, "examples"),
    ok = py:exec(iolist_to_binary(io_lib:format("import sys; sys.path.insert(0, ~p)", [Examples]))),
    {ok, Loop} = py_nif:event_loop_new(),
    {ok, Worker} = py_event_worker:start_link(<<"safety-example">>, Loop),
    ok = py_nif:event_loop_set_worker(Loop, Worker),
    try
        Capacity = 1,
        MaxBytes = 4096,
        ok = py_nif:work_admission_configure(Loop, self(), Capacity, MaxBytes),
        Work = make_ref(),
        ok = py_nif:submit_task_bounded(Loop, self(), Work, <<"safety_admission">>, <<"work">>, [], #{}),
        {ok, none} = control(Loop, ready),
        #{count := 1, bytes := Bytes} = py_nif:work_admission_info(Loop),
        true = Bytes > 0 andalso Bytes =< MaxBytes,
        reject_from_another_caller(Loop),
        {ok, 0} = control(Loop, rejected_count),
        io:format("Shared destination rejected before enqueue.~n"),

        {ok, none} = control(Loop, cancel_and_acknowledge),
        #{count := 1, bytes := Bytes} = py_nif:work_admission_info(Loop),
        reject_from_another_caller(Loop),
        io:format("Cancellation acknowledged; unfinished cleanup still holds capacity.~n"),

        {ok, none} = control(Loop, allow_completion),
        {ok, <<"finished">>} = py_event_loop:await(Work, 5000),
        await_released(Loop, erlang:monotonic_time(millisecond) + 5000),
        Reuse = make_ref(),
        ok = py_nif:submit_task_bounded(Loop, self(), Reuse, <<"builtins">>, <<"len">>, [<<>>], #{}),
        {ok, 0} = py_event_loop:await(Reuse, 5000),
        await_released(Loop, erlang:monotonic_time(millisecond) + 5000),
        {ok, 0} = control(Loop, rejected_count),
        io:format("Completion released count and bytes; a new invocation succeeded.~n")
    after
        py_nif:work_admission_close(Loop),
        py_event_worker:stop(Worker),
        py_nif:event_loop_release_python_loop(Loop),
        py_nif:event_loop_destroy(Loop),
        application:stop(erlang_python)
    end.

reject_from_another_caller(Loop) ->
    Parent = self(),
    spawn(fun() ->
        Result = py_nif:submit_task_bounded(
            Loop, self(), make_ref(), <<"safety_admission">>, <<"rejected">>, [], #{}),
        Parent ! {admission_attempt, Result}
    end),
    receive
        {admission_attempt, {error, overloaded}} -> ok;
        {admission_attempt, Other} -> error({expected_rejection, Other})
    after 5000 -> error(admission_attempt_timeout)
    end.

%% Cleanup controls deliberately use the existing legacy path, one at a time.
%% They must remain callable while the invocation gate is full.
control(Loop, Function) ->
    Ref = make_ref(),
    ok = py_nif:submit_task(Loop, self(), Ref, <<"safety_admission">>, atom_to_binary(Function), [], #{}),
    py_event_loop:await(Ref, 5000).

%% The native count is the evidence of release, not elapsed time. Results can
%% arrive before a Task's done callback returns its credits.
await_released(Loop, Deadline) ->
    case py_nif:work_admission_info(Loop) of
        #{count := 0, bytes := 0} -> ok;
        #{count := 1} ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> erlang:yield(), await_released(Loop, Deadline);
                false -> error(completion_accounting_timeout)
            end
    end.

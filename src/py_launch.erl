%% Generic managed Python file launcher. No listeners or distribution are started.
-module(py_launch).
-export([start/0]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

start() ->
    try
        application:load(erlang_python),
        application:set_env(erlang_python, num_contexts, 1),
        application:set_env(erlang_python, event_loop_pool_size, 1),
        {ok, _} = application:ensure_all_started(erlang_python),
        Ctx = py:context(1),
        ok = py_context:exec(Ctx,
            <<"import json, os, sys; "
              "sys.path[:0] = json.loads(os.environ['PYBEAM_BOOTSTRAP'])['python_paths']">>),
        {ok, _} = py_context:call(Ctx, 'pybeam.runtime.loader', load, []),
        _ = gen_event:delete_handler(erl_signal_server, erl_signal_handler, []),
        ok = gen_event:add_handler(erl_signal_server, ?MODULE, self()),
        ok = os:set_signal(sigterm, handle),
        Shutdown = os:getenv("PYBEAM_SHUTDOWN"),
        Budget = list_to_integer(os:getenv("PYBEAM_SHUTDOWN_TIMEOUT_MS")),
        true = Budget > 0,
        ok = py_context:start_loop(Ctx),
        {ok, Task} = py_context:submit(Ctx, 'pybeam.runtime.loader', invoke, []),
        {Status, Deadline} = wait(Ctx, Task, Shutdown, Budget),
        finish(Ctx, Status, Deadline)
    catch
        Class:Reason:Stack ->
            io:format(standard_error, "PyBeam runtime failed: ~p:~p~n~p~n",
                      [Class, Reason, Stack]),
            halt(1)
    end.

wait(Ctx, Task, Shutdown, Budget) ->
    receive
        {async_result, Task, {ok, Status}} when is_integer(Status) ->
            {Status, deadline(Budget)};
        {async_result, Task, Error} ->
            io:format(standard_error, "PyBeam entrypoint failed: ~p~n", [Error]),
            {1, deadline(Budget)};
        {notify, Signal} when Signal =:= sigterm; Signal =:= sigint ->
            {case Signal of sigint -> 130; sigterm -> 143 end, deadline(Budget)};
        {py_loop_exit, Ctx, Error} ->
            io:format(standard_error, "PyBeam event loop exited: ~p~n", [Error]),
            {1, deadline(Budget)}
    after 25 ->
        %% ERTS reserves SIGINT for its break handler. The host also records the
        %% signal so +Bi can suppress that handler without losing cancellation.
        case file:read_file(Shutdown) of
            {ok, <<"2">>} -> {130, deadline(Budget)};
            {ok, <<"15">>} -> {143, deadline(Budget)};
            _ -> wait(Ctx, Task, Shutdown, Budget)
        end
    end.

deadline(Budget) -> erlang:monotonic_time(millisecond) + Budget.

remaining(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Milliseconds when Milliseconds > 0 -> Milliseconds;
        _ -> error(shutdown_deadline_exceeded)
    end.

%% Bound even APIs whose internal control calls have their own longer waits.
bounded(Operation, Deadline) ->
    Timeout = remaining(Deadline),
    {Pid, Monitor} = spawn_monitor(fun() -> exit({cleanup_result, Operation()}) end),
    receive
        {'DOWN', Monitor, process, Pid, {cleanup_result, Result}} ->
            _ = remaining(Deadline),
            Result;
        {'DOWN', Monitor, process, Pid, Reason} -> error({cleanup_step_failed, Reason})
    after Timeout ->
        exit(Pid, kill),
        error(shutdown_deadline_exceeded)
    end.

finish(Ctx, Status, Deadline) ->
    try
        ok = marker("PYBEAM_COMPLETION", integer_to_binary(Status)),
        %% Python None is converted to the atom none by py_convert.c.
        {ok, none} = bounded(fun() ->
            Left = remaining(Deadline),
            py_context:submit_await(Ctx, 'pybeam.runtime.loader', shutdown, [Left], #{}, Left)
        end, Deadline),
        ok = bounded(fun() -> py_context:stop_loop(Ctx, remaining(Deadline)) end, Deadline),
        %% stop_loop replies ok even after an interrupted driver exit. Require
        %% the driver's actual normal result, not just the control reply.
        DriverTimeout = remaining(Deadline),
        receive
            {py_loop_exit, Ctx, {ok, <<"stopped">>}} -> ok;
            {py_loop_exit, Ctx, LoopError} -> error({driver_shutdown_failed, LoopError})
        after DriverTimeout -> error(driver_shutdown_unacknowledged)
        end,
        ok = bounded(fun() -> application:stop(erlang_python) end, Deadline),
        _ = remaining(Deadline),
        ok = marker("PYBEAM_CLEANUP", <<"clean">>),
        halt(Status)
    catch
        Class:Reason ->
            io:format(standard_error, "PyBeam cleanup failed (entry status ~p): ~p:~p~n",
                      [Status, Class, Reason]),
            halt(case Status of 0 -> 1; _ -> Status end)
    end.

marker(Variable, Value) ->
    Path = os:getenv(Variable),
    Pending = Path ++ ".tmp",
    ok = file:write_file(Pending, Value),
    file:rename(Pending, Path).

init(Owner) -> {ok, Owner}.
handle_event(Signal, Owner) -> Owner ! {notify, Signal}, {ok, Owner}.
handle_call(_Request, Owner) -> {ok, ok, Owner}.
handle_info(_Message, Owner) -> {ok, Owner}.
terminate(_Reason, _Owner) -> ok.
code_change(_OldVersion, Owner, _Extra) -> {ok, Owner}.

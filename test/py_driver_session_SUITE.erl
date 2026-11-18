-module(py_driver_session_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1, concurrent_resume/1,
         startup_rollback/1, claimed_before_running/1, native_dispatch_restores_running_loop/1]).

all() -> [concurrent_resume, startup_rollback, claimed_before_running,
          native_dispatch_restores_running_loop].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python), Config.
end_per_suite(_) -> application:stop(erlang_python).

context() ->
    {ok, C} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    ok = py_context:exec(C, iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [Dir]))), C.

concurrent_resume(_) ->
    A = context(), B = context(), Inspector = context(),
    Parent = self(),
    py_callback:register(driver_session_echo, fun([Value]) -> Value end),
    py_callback:register(composition_enter, fun([_Group]) -> ok end),
    try
        {ok, 42} = py_context:submit_await(A, asyncio, sleep, [0.001],
                                         #{<<"result">> => 42}, 1000),
        {ok, true} = py_context:call(Inspector, py_test_driver_session, install, []),
        [spawn(fun() -> Parent ! {started, C, py_context:start_loop(C, #{owner => Parent})} end)
         || C <- [A, B]],
        Results = [receive {started, C, R} -> {C, R}
                   after 5000 -> error(driver_start_timeout) end || _ <- [1, 2]],
        [Winner] = [C || {C, ok} <- Results],
        [_Loser] = [C || {C, {error, {'RuntimeError', _}}} <- Results],
        {ok, true} = py_context:call(Inspector, py_test_driver_session, inspect, []),
        {ok, 42} = py_context:submit_await(Winner, py_test_driver_session, continue_work,
                                         [], #{}, 10000),
        ok = py_context:stop_loop(Winner),
        %% The same context may start again after normal close/rebind.
        ok = py_context:start_loop(Winner),
        {ok, 42} = py_context:submit_await(Winner, asyncio, sleep, [0.001],
                                         #{<<"result">> => 42}, 1000),
        ok = py_context:stop_loop(Winner)
    after
        py_callback:unregister(driver_session_echo),
        py_callback:unregister(composition_enter),
        [py_context:stop(C) || C <- [A, B, Inspector]]
    end.

claimed_before_running(_) ->
    C = context(), Inspector = context(),
    try
        {ok, 42} = py_context:submit_await(C, asyncio, sleep, [0.001],
                                         #{<<"result">> => 42}, 1000),
        {ok, true} = py_context:call(C, py_test_driver_session, claim_without_running, []),
        {ok, true} = py_context:call(Inspector, py_test_driver_session, reject_foreign_close, []),
        {ok, true} = py_context:call(C, py_test_driver_session, release_without_running, []),
        ok = py_context:start_loop(C),
        ok = py_context:stop_loop(C)
    after py_context:stop(C), py_context:stop(Inspector) end.

startup_rollback(_) ->
    C = context(),
    try
        {ok, 42} = py_context:submit_await(C, asyncio, sleep, [0.001],
                                         #{<<"result">> => 42}, 1000),
        {ok, true} = py_context:call(C, py_test_driver_session, startup_failure, []),
        ok = py_context:start_loop(C),
        {ok, 42} = py_context:submit_await(C, asyncio, sleep, [0.001],
                                         #{<<"result">> => 42}, 1000),
        ok = py_context:stop_loop(C)
    after py_context:stop(C) end.

native_dispatch_restores_running_loop(_) ->
    {ok, Loop} = py_nif:event_loop_new(),
    {ok, Worker} = py_event_worker:start_link(<<"native_dispatch_probe">>, Loop),
    ok = py_nif:event_loop_set_worker(Loop, Worker),
    {ok, Driver} = py_context:start_link(erlang:unique_integer([positive]), worker,
                                       #{managed_loop => {dedicated, Loop, Worker}}),
    Inspector = context(),
    try
        ok = py_context:start_loop(Driver),
        ok = sys:suspend(Worker),
        try
            {ok, true} = py_context:call(Inspector, py_test_driver_session, track_running_loop, [Loop]),
            try
                Result = make_ref(),
                ok = py_nif:submit_task(Loop, self(), Result, <<"operator">>, <<"truth">>,
                                        [true], #{}),
                ok = py_nif:process_ready_tasks(Loop),
                {ok, true} = py_event_loop:await(Result, 1000),
                {ok, true} = py_context:call(Inspector, py_test_driver_session, running_loop_restored, [])
            after
                py_context:call(Inspector, py_test_driver_session, stop_tracking_running_loop, [])
            end
        after
            ok = sys:resume(Worker)
        end,
        ok = py_context:stop_loop(Driver)
    after
        py_context:stop(Driver),
        py_context:stop(Inspector)
    end.

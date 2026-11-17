-module(py_context_cleanup_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1, live_context_not_reaped/1,
         killed_idle_context_reaped/1, concurrent_reaping/1,
         idle_destroy_is_prompt/1]).
all() -> [live_context_not_reaped, killed_idle_context_reaped, concurrent_reaping,
          idle_destroy_is_prompt].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python), Config.
end_per_suite(_) -> application:stop(erlang_python).

live_context_not_reaped(_) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    Native = py_context:get_nif_ref(Ctx),
    pending = py_nif:context_cleanup_status(Native),
    {error, context_alive} = py_context:reap_dead(Ctx, Native),
    true = is_process_alive(Ctx),
    ok = py_context:destroy(Ctx),
    clean = py_nif:context_cleanup_status(Native),
    [] = ets:lookup(py_context_refs, Ctx).

killed_idle_context_reaped(_) ->
    {Ctx, Native} = killed_idle(),
    pending = py_nif:context_cleanup_status(Native),
    [{Ctx, Native}] = ets:lookup(py_context_refs, Ctx),
    clean = py_context:reap_dead(Ctx, Native),
    [] = ets:lookup(py_context_refs, Ctx),
    clean = py_nif:context_cleanup_status(Native).

concurrent_reaping(_) ->
    {Ctx, Native} = killed_idle(),
    Parent = self(),
    [spawn(fun() -> Parent ! {reaped, py_context:reap_dead(Ctx, Native)} end)
        || _ <- lists:seq(1, 32)],
    Results = [receive {reaped, Result} -> Result after 5000 -> error(reap_timeout) end
        || _ <- lists:seq(1, 32)],
    true = lists:member(clean, Results),
    true = lists:all(fun(Status) -> Status =:= clean orelse Status =:= pending end, Results),
    clean = py_nif:context_cleanup_status(Native),
    [] = ets:lookup(py_context_refs, Ctx).

%% Joining an idle worker thread must not wait out a fixed poll interval.
idle_destroy_is_prompt(_) ->
    Times = [begin
                 {ok, Ctx} = py_context:new(#{mode => worker}),
                 Native = py_context:get_nif_ref(Ctx),
                 {Micros, ok} = timer:tc(fun() -> py_context:destroy(Ctx) end),
                 clean = py_nif:context_cleanup_status(Native),
                 Micros
             end || _ <- lists:seq(1, 5)],
    true = lists:min(Times) < 50000.

killed_idle() ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    unlink(Ctx),
    Native = py_context:get_nif_ref(Ctx),
    Mon = monitor(process, Ctx),
    exit(Ctx, kill),
    receive {'DOWN', Mon, process, Ctx, killed} -> ok after 5000 -> error(kill_timeout) end,
    {Ctx, Native}.

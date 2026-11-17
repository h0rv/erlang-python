-module(py_worker_pool_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         sleeping/1, cpu_parallel/1, reuse/1, capacity/1, portable_env/1, callbacks/1,
         isolated_state/1]).

all() -> [reuse, portable_env, capacity, callbacks, sleeping, cpu_parallel, isolated_state].
init_per_suite(Config) ->
    application:load(erlang_python),
    application:set_env(erlang_python, worker_pool_max, 16),
    {ok, _} = application:ensure_all_started(erlang_python),
    Config.
end_per_suite(_) ->
    application:stop(erlang_python),
    application:unset_env(erlang_python, worker_pool_max).

with_context(Fun) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    try
        ok = py_context:exec(Ctx, iolist_to_binary(io_lib:format(
            "import sys; sys.path.insert(0, ~p)", [Dir]))),
        Fun(Ctx)
    after py_context:destroy(Ctx) end.

sleeping(_) -> with_context(fun(Ctx) ->
    {ok, Elapsed} = py_context:call(Ctx, py_test_worker_pool, sleeping, [], #{}, 30000),
    ct:pal("16 sleeping actors: ~.3f s (serial 3.200 s)", [Elapsed]),
    true = Elapsed < 1.6
end).

isolated_state(_) -> with_context(fun(Ctx) ->
    {ok, none} = py_context:call(Ctx, py_test_worker_pool, isolated_state, [], #{}, 30000)
end).

callbacks(_) -> with_context(fun(Ctx) ->
    py_callback:register(worker_pool_echo, fun([]) -> ok end),
    try
        {ok, _} = py_context:call(Ctx, py_test_worker_pool, callbacks, [], #{}, 30000)
    after py_callback:unregister(worker_pool_echo) end
end).

cpu_parallel(_) -> with_context(fun(Ctx) ->
    case py_context:call(Ctx, py_test_worker_pool, cpu_parallel_supported, [], #{}) of
        {ok, true} ->
            {ok, {Single, Parallel}} = py_context:call(Ctx, py_test_worker_pool, cpu_parallel,
                [], #{}, 30000),
            ct:pal("CPU actors: single ~.3f s, eight ~.3f s, ratio ~.3f", [Single, Parallel, Parallel / Single]),
            true = Parallel < Single * 2.0;
        {ok, false} -> {skip, requires_free_threaded_python314}
    end
end).

reuse(_) -> with_context(fun(_) ->
    Worker = py_worker_pool:checkout(undefined),
    {ok, {Loop, 1}} = py_context:call(Worker, py_test_worker_pool, loop_identity, [], #{}),
    ok = py_worker_pool:checkin(Worker),
    Worker = py_worker_pool:checkout(Worker),
    {ok, {Loop, 2}} = py_context:call(Worker, py_test_worker_pool, loop_identity, [], #{}),
    ok = py_worker_pool:checkin(Worker),
    {error, not_holder} = py_worker_pool:checkin(Worker)
end).

portable_env(_) ->
    First = py_worker_pool:checkout(undefined),
    Second = py_worker_pool:checkout(undefined),
    try
        {ok, Env} = py_context:create_local_env(First),
        {ok, Local} = py_context:eval_ref(First, <<"[1, 2, 3]">>, #{}, Env),
        {ok, Ref} = py_context:call(First, '_erlang_impl._actor_data', portable, [Local], #{}),
        {ok, Fn} = py_context:eval_ref(Second, <<"lambda xs: sum(xs)">>, #{}, Env),
        {ok, Args} = py_context:eval_ref(Second, <<"(xs,)">>, #{<<"xs">> => Ref}, Env),
        {ok, Kwargs} = py_context:eval_ref(Second, <<"{}">>, #{}, Env),
        {ok, _} = py_context:apply_ref(Second, Fn, Args, Kwargs, Env)
    after py_worker_pool:checkin(First), py_worker_pool:checkin(Second) end.

capacity(_) ->
    Parent = self(),
    Holders = [spawn(fun() ->
        Worker = py_worker_pool:checkout(undefined),
        Parent ! {leased, self(), Worker},
        receive release -> py_worker_pool:checkin(Worker) end
    end) || _ <- lists:seq(1, 16)],
    Workers = [receive {leased, _, W} -> W after 5000 -> error(lease_timeout) end
        || _ <- Holders],
    16 = length(lists:usort(Workers)),
    First = gen_server:send_request(py_worker_pool, {checkout, undefined}),
    Second = gen_server:send_request(py_worker_pool, {checkout, undefined}),
    #{queue := Queue} = sys:get_state(py_worker_pool),
    2 = queue:len(Queue),
    [Holder | Rest] = Holders,
    exit(Holder, kill),
    {reply, W} = gen_server:wait_response(First, 5000),
    true = lists:member(W, Workers),
    #{queue := Pending} = sys:get_state(py_worker_pool),
    1 = queue:len(Pending),
    ok = py_worker_pool:checkin(W),
    {reply, W} = gen_server:wait_response(Second, 5000),
    ok = py_worker_pool:checkin(W),
    [Pid ! release || Pid <- Rest],
    [py_worker_pool:drain(Pid) || Pid <- Holders],
    ok.

-module(py_worker_pool_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         sleeping/1, cpu_parallel/1, reuse/1, capacity/1, portable_env/1, callbacks/1,
         isolated_state/1, policy_independent/1, factory_drain/1, exception_identity/1,
         preferred_release/1, preferred_timeout/1, preferred_fifo/1, preferred_races/1,
         background_tasks/1, background_cleanup/1, worker_wakeups/1]).

all() -> [reuse, portable_env, capacity, callbacks, sleeping, cpu_parallel, isolated_state,
          policy_independent, factory_drain, exception_identity,
          preferred_release, preferred_timeout, preferred_fifo, preferred_races,
          background_tasks, background_cleanup, worker_wakeups].
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
    {ok, none} = py_context:call(Ctx, py_test_worker_pool, sleeping, [], #{}, 30000)
end).

background_tasks(_) -> with_context(fun(Ctx) ->
    {ok, {true, true}} = py_context:call(Ctx, py_test_worker_tasks, background_progress, [], #{}, 30000)
end).

worker_wakeups(_) ->
    with_context(fun(Ctx) ->
        {ok, none} = py_context:call(Ctx, py_test_worker_tasks, queued_wakeups, [], #{}, 30000),
        {ok, none} = py_context:call(Ctx, py_test_worker_tasks, prepare_shutdown, [], #{}, 30000)
    end),
    with_context(fun(Ctx) ->
        {ok, none} = py_context:call(Ctx, py_test_worker_tasks, check_shutdown, [], #{}, 30000)
    end),
    with_context(fun(Worker) -> with_context(fun(Control) ->
        Ref = py_context:get_nif_ref(Worker),
        {ok, none} = py_context:call(Control, py_test_worker_tasks, reset_block, []),
        Block = make_ref(),
        {enqueued, Block} = py_nif:context_call_async(Ref, self(), Block,
            <<"py_test_worker_tasks">>, <<"blocking_request">>, [], #{}),
        {ok, none} = py_context:call(Control, py_test_worker_tasks, wait_block_started, []),
        Requests = [make_ref() || _ <- lists:seq(1, 20000)],
        try
            [{enqueued, R} = py_nif:context_call_async(Ref, self(), R,
                <<"builtins">>, <<"len">>, [[]], #{}) || R <- Requests]
        after
            {ok, none} = py_context:call(Control, py_test_worker_tasks, release_block, [])
        end,
        receive {py_result, Block, {ok, none}} -> ok after 30000 -> error(block_stuck) end,
        [receive {py_result, R, {ok, 0}} -> ok after 30000 -> error(request_lost) end
            || R <- Requests]
    end) end).

background_cleanup(_) -> with_context(fun(Ctx) ->
    Hold = fun(Preferred) ->
        Parent = self(),
        Holder = spawn(fun() ->
            Worker = py_worker_pool:checkout(Preferred),
            Parent ! {leased_task_worker, self()},
            receive release -> py_worker_pool:checkin(Worker) end
        end),
        receive {leased_task_worker, Holder} -> Holder end
    end,
    Release = fun(Holder) ->
        Holder ! release,
        py_worker_pool:drain(Holder)
    end,
    py_callback:register(worker_task_hold, fun([Actor]) ->
        #{ctx := Worker} = sys:get_state(Actor), Hold(Worker)
    end),
    py_callback:register(worker_task_block, fun([Actor]) ->
        #{ctx := Worker} = sys:get_state(Actor),
        spawn(fun() ->
            Worker = py_worker_pool:checkout(Worker),
            {ok, none} = py_context:call(Worker, py_test_worker_tasks, blocking_request, [], #{}, 30000),
            py_worker_pool:checkin(Worker)
        end)
    end),
    py_callback:register(worker_task_object, fun([Actor]) ->
        #{object := Object} = sys:get_state(Actor), Object
    end),
    py_callback:register(worker_task_hold_all, fun([]) ->
        [Hold(undefined) || _ <- lists:seq(1, 16)]
    end),
    py_callback:register(worker_task_release, fun([Holder]) -> Release(Holder) end),
    py_callback:register(worker_task_release_all, fun([Holders]) ->
        [Release(Holder) || Holder <- Holders], ok
    end),
    try
        {ok, none} = py_context:call(Ctx, py_test_worker_tasks, background_cleanup, [], #{}, 60000)
    after
        [py_callback:unregister(Name) || Name <- [worker_task_block, worker_task_object, worker_task_hold, worker_task_hold_all,
            worker_task_release, worker_task_release_all]]
    end
end).

isolated_state(_) -> with_context(fun(Ctx) ->
    {ok, none} = py_context:call(Ctx, py_test_worker_pool, isolated_state, [], #{}, 30000)
end).

policy_independent(_) -> with_context(fun(Ctx) ->
    ok = py_context:exec(Ctx, <<
        "import asyncio\n"
        "from _erlang_impl import get_event_loop_policy\n"
        "_old_policy = asyncio.get_event_loop_policy()\n"
        "asyncio.set_event_loop_policy(get_event_loop_policy())\n"
    >>),
    First = py_worker_pool:checkout(undefined),
    Second = py_worker_pool:checkout(undefined),
    try
        {ok, none} = py_context:call(First, '_erlang_impl._actor_data', close_worker_loop, [], #{}),
        {ok, none} = py_context:call(Second, '_erlang_impl._actor_data', close_worker_loop, [], #{}),
        {ok, _} = py_context:call(First, py_test_worker_pool, loop_identity, [], #{}),
        {ok, _} = py_context:call(Second, py_test_worker_pool, loop_identity, [], #{})
    after
        py_worker_pool:checkin(First),
        py_worker_pool:checkin(Second),
        py_context:exec(Ctx, <<"asyncio.set_event_loop_policy(_old_policy)">>)
    end
end).

exception_identity(_) -> with_context(fun(Ctx) ->
    {ok, none} = py_context:call(Ctx, py_test_worker_errors, exception_identity, [], #{}, 30000)
end).

factory_drain(_) -> with_context(fun(Ctx) ->
    Parent = self(),
    py_callback:register(review_factory_wait, fun([]) ->
        Parent ! {factory_waiting, self()},
        receive continue -> ok end
    end),
    {ok, Factory} = py_context:eval(Ctx,
        <<"__import__('erlang')._actor_retain(__import__('py_test_worker_factory').factory)">>),
    Holder = spawn(fun() ->
        Gate = py_nif:actor_gate_new(1, 1024),
        Object = py_nif:actor_object_new(),
        ok = py_actor_registry:own(self(), Gate, Object),
        Leased = py_worker_pool:checkout(undefined),
        Parent ! {held, Gate, Object, Leased},
        py_context:call(Leased, '_erlang_impl._actor_data', initialize,
            [Factory, Object], #{}, infinity)
    end),
    {Gate, Object, Worker} = receive {held, G, O, W} -> {G, O, W} end,
    Callback = receive {factory_waiting, Pid} -> Pid end,
    try
        exit(Holder, kill),
        Drain = gen_server:send_request(py_worker_pool, {drain, Holder}),
        timeout = gen_server:wait_response(Drain, 500),
        Released = gen_server:send_request(py_actor_registry, {release, Gate}),
        timeout = gen_server:wait_response(Released, 0),
        #{busy := Busy} = sys:get_state(py_worker_pool),
        {Holder, _} = maps:get(Worker, Busy),
        Callback ! continue,
        {reply, ok} = gen_server:wait_response(Drain, 5000),
        {reply, ok} = gen_server:wait_response(Released, 5000),
        {error, _} = py_context:call(Ctx, '_erlang_impl._actor_data', portable, [Object], #{}),
        Worker = py_worker_pool:checkout(Worker),
        {ok, 0} = py_context:call(Worker, builtins, len, [[]], #{}),
        ok = py_worker_pool:checkin(Worker)
    after
        Callback ! continue,
        py_callback:unregister(review_factory_wait)
    end
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
            {ok, none} = py_context:call(Ctx, py_test_worker_pool, cpu_parallel,
                [], #{}, 30000);
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

preferred_state() ->
    First = spawn(fun barrier_worker/0),
    Second = spawn(fun barrier_worker/0),
    {First, Second, #{free => [Second], busy => #{First => {self(), make_ref()}},
        queue => queue:new(), workers => [First, Second], max => 2, drains => #{}}}.

barrier_worker() ->
    receive {pool_barrier, From, Ref} -> From ! {Ref, ok}, barrier_worker() end.

clean_preferred(State) ->
    [demonitor(Mon, [flush]) || {_, Mon} <- maps:values(maps:get(busy, State))],
    [begin erlang:cancel_timer(Timer), demonitor(Mon, [flush]) end
        || {_, Mon, _, Timer} <- queue:to_list(maps:get(queue, State)), is_reference(Timer)],
    [exit(Worker, kill) || Worker <- maps:get(workers, State)].

preferred_release(_) ->
    {First, Second, State} = preferred_state(),
    Tag = make_ref(),
    {noreply, Waiting} = py_worker_pool:handle_call({checkout, First}, {self(), Tag}, State),
    [{_, Mon, First, Timer}] = queue:to_list(maps:get(queue, Waiting)),
    true = is_reference(Timer),
    [Second] = maps:get(free, Waiting),
    {reply, ok, Served} = py_worker_pool:handle_call({checkin, First}, {self(), make_ref()}, Waiting),
    receive {Tag, First} -> ok end,
    false = erlang:read_timer(Timer),
    {noreply, Served} = py_worker_pool:handle_info({preferred_timeout, Mon}, Served),
    clean_preferred(Served).

preferred_timeout(_) ->
    {First, Second, State} = preferred_state(),
    Tag = make_ref(),
    {noreply, Waiting} = py_worker_pool:handle_call({checkout, First}, {self(), Tag}, State),
    [{_, Mon, First, _}] = queue:to_list(maps:get(queue, Waiting)),
    receive {preferred_timeout, Mon} -> ok end,
    {noreply, Served} = py_worker_pool:handle_info({preferred_timeout, Mon}, Waiting),
    receive {Tag, Second} -> ok end,
    true = queue:is_empty(maps:get(queue, Served)),
    {noreply, Served} = py_worker_pool:handle_info({preferred_timeout, Mon}, Served),
    clean_preferred(Served).

preferred_fifo(_) ->
    {First, Second, Initial} = preferred_state(),
    State = Initial#{free := [], busy := #{First => {self(), make_ref()}, Second => {self(), make_ref()}}},
    A = make_ref(), B = make_ref(),
    {noreply, One} = py_worker_pool:handle_call({checkout, First}, {self(), A}, State),
    {noreply, Two} = py_worker_pool:handle_call({checkout, undefined}, {self(), B}, One),
    [{_, Mon, _, _}, {_, NextMon, _, _}] = queue:to_list(maps:get(queue, Two)),
    {noreply, Expired} = py_worker_pool:handle_info({preferred_timeout, Mon}, Two),
    [Mon, NextMon] = [M || {_, M, _, _} <- queue:to_list(maps:get(queue, Expired))],
    {reply, ok, ServedA} = py_worker_pool:handle_call({checkin, Second}, {self(), make_ref()}, Expired),
    receive {A, Second} -> ok end,
    {reply, ok, ServedB} = py_worker_pool:handle_call({checkin, Second}, {self(), make_ref()}, ServedA),
    receive {B, Second} -> ok end,
    clean_preferred(ServedB).

preferred_races(_) ->
    Orders = [[timeout, checkin, death], [timeout, death, checkin],
              [checkin, timeout, death], [checkin, death, timeout],
              [death, timeout, checkin], [death, checkin, timeout]],
    lists:foreach(fun preferred_race/1, Orders).

preferred_race(Order) ->
    {First, _, State} = preferred_state(),
    Caller = spawn(fun() -> receive stop -> ok end end),
    {noreply, Waiting} = py_worker_pool:handle_call({checkout, First}, {Caller, make_ref()}, State),
    [{_, Mon, _, Timer}] = queue:to_list(maps:get(queue, Waiting)),
    erlang:cancel_timer(Timer),
    Final = lists:foldl(fun(Event, Current) ->
        Next = case Event of
            timeout ->
                {noreply, N} = py_worker_pool:handle_info({preferred_timeout, Mon}, Current), N;
            checkin ->
                {reply, ok, N} = py_worker_pool:handle_call({checkin, First}, {self(), make_ref()}, Current), N;
            death ->
                Watch = monitor(process, Caller),
                exit(Caller, kill),
                receive {'DOWN', Watch, process, Caller, _} -> ok end,
                Held = [{Ctx, M} || {Ctx, {Pid, M}} <- maps:to_list(maps:get(busy, Current)), Pid =:= Caller],
                DownMon = case Held of [] -> Mon; [{_, M}] -> M end,
                {noreply, N} = py_worker_pool:handle_info({'DOWN', DownMon, process, Caller, killed}, Current),
                case Held of
                    [] -> N;
                    [{Ctx, _}] ->
                        receive {drained, Ctx, Caller} -> ok end,
                        {noreply, Drained} = py_worker_pool:handle_info({drained, Ctx, Caller}, N), Drained
                end
        end,
        Free = maps:get(free, Next),
        length(Free) =:= length(lists:usort(Free)) orelse error(duplicate_worker),
        [] = [W || W <- Free, maps:is_key(W, maps:get(busy, Next))],
        Next
    end, Waiting, Order),
    true = queue:is_empty(maps:get(queue, Final)),
    0 = map_size(maps:get(busy, Final)),
    2 = length(maps:get(free, Final)),
    {noreply, Final} = py_worker_pool:handle_info({preferred_timeout, Mon}, Final),
    clean_preferred(Final).

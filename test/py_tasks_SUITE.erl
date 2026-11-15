-module(py_tasks_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1, killed_child/1,
         killed_context/1, killed_group/1, queued_ticket/1, killed_before_execution/1,
         retained_exception_lifecycle/1]).
all() -> [killed_child, killed_context, killed_group, queued_ticket, killed_before_execution,
          retained_exception_lifecycle].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python), Config.
end_per_suite(_) -> application:stop(erlang_python).
killed_child(_) -> killed(<<"child">>).
killed_context(_) -> killed(<<"context">>).
killed_group(_) -> killed(<<"group">>).

killed(Mode) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    ok = py_context:exec(Ctx, iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [Dir]))),
    Baseline = ets:info(py_context_refs, size),
    Parent = self(),
    py_callback:register(task_test_capture, fun([Group]) ->
        #{jobs := Jobs} = sys:get_state(Group),
        [#{ctx := Owned, native := Native}] = maps:values(Jobs),
        Parent ! {captured, Owned, Native},
        ok
    end),
    py_callback:register(task_test_kill, fun([Pid]) ->
        Mon = monitor(process, Pid),
        exit(Pid, kill),
        receive {'DOWN', Mon, process, Pid, _} -> ok after 5000 -> error(kill_timeout) end
    end),
    py_callback:register(task_test_down, fun([Pid]) ->
        Mon = monitor(process, Pid),
        receive {'DOWN', Mon, process, Pid, _} -> ok after 5000 -> error(orphan_process) end
    end),
    py_callback:register(task_test_reaped, fun([]) -> wait_contexts(Baseline, 1000) end),
    try
        ok = py_context:start_loop(Ctx),
        {ok, true} = py_context:submit_await(Ctx, py_test_tasks, killed, [Mode], #{}, 10000),
        receive {captured, Owned, Native} ->
            false = is_process_alive(Owned),
            [] = ets:lookup(py_context_refs, Owned),
            clean = py_nif:context_cleanup_status(Native)
        after 5000 -> error(no_native_context_proof) end,
        ok = py_context:stop_loop(Ctx)
    after
        [py_callback:unregister(Name) || Name <- [task_test_kill, task_test_down, task_test_reaped, task_test_capture]],
        py_context:destroy(Ctx)
    end.

queued_ticket(_) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    ok = py_context:exec(Ctx, iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [Dir]))),
    {ok, Group} = py_task_group:start_link(1, 4),
    unlink(Group),
    {ok, {Group, Gate}} = gen_server:call(Group, gate),
    try
        {ok, Ticket} = py_context:call(Ctx, py_test_actor_data, reserve, [Gate, 4]),
        ok = sys:suspend(py_thread_handler),
        try
            {ok, _} = py_context:call(Ctx, py_test_tasks, enqueue,
                [Group, Gate, Ticket, {bytes, <<"work">>}]),
            {ok, none} = py_context:call(Ctx, py_test_actor_data, abort, [Ticket]),
            #{count := 1, bytes := 4, unsettled := 1} = py_nif:actor_gate_info(Gate),
            {error, _} = py_context:call(Ctx, py_test_actor_data, reserve, [Gate, 1])
        after sys:resume(py_thread_handler) end,
        wait_ticket(Ticket, 1000),
        #{jobs := Jobs} = sys:get_state(Group),
        [{Pid, #{native := Native}}] = maps:to_list(Jobs),
        {ok, {bytes, <<"work">>}} = gen_server:call(Group, {wait, Pid}, infinity),
        clean = py_nif:context_cleanup_status(Native),
        #{count := 0, bytes := 0, unsettled := 0} = py_nif:actor_gate_info(Gate),
        ok = gen_server:call(Group, {shutdown, 1000}, infinity)
    after gen_server:stop(Group, normal, infinity), py_context:destroy(Ctx) end.

killed_before_execution(_) ->
    {ok, Source} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    ok = py_context:exec(Source, iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [Dir]))),
    {ok, Factory} = py_context:eval(Source,
        <<"__import__('erlang')._actor_retain(__import__('py_test_tasks').unstarted_body)">>),
    {ok, Group} = py_task_group:start_link(1, 4),
    unlink(Group),
    #{sup := Sup} = sys:get_state(Group),
    {ok, {Group, Gate}} = gen_server:call(Group, gate),
    try
        {ok, Ticket} = py_context:call(Source, py_test_actor_data, reserve, [Gate, 4]),
        ok = py_nif:actor_ticket_commit(Ticket, Gate, 4),
        Id = make_ref(),
        Spec = #{id => Id, start => {py_task, start_link, [Group, Factory, Ticket, <<"work">>]},
                 restart => temporary, shutdown => infinity},
        {ok, Pid} = supervisor:start_child(Sup, Spec),
        {Ctx, Object, Native} = gen_server:call(Pid, info),
        {error, context_cleanup_unacknowledged} = py_nif:task_ticket_reap(Ticket, Native),
        %% Freeze exactly the admitted-before-execute handoff. No Python job
        %% runs in this interval; the real OTP child/context/gate remain live.
        ok = sys:suspend(Pid),
        _ = sys:replace_state(Group, fun(State) ->
            Mon = monitor(process, Pid),
            Job = #{id => Id, ctx => Ctx, native => Native, object => Object,
                    ticket => Ticket, mon => Mon, result => pending, waiters => [],
                    ready => false, down => false, reaping => false, reaped => false,
                    observed => false, cancel_sent => false, seal_sent => false, sealed => false},
            State#{jobs := #{Pid => Job}}
        end),
        Pid ! run,
        Mon = monitor(process, Pid),
        exit(Ctx, kill),
        receive {'DOWN', Mon, process, Pid, _} -> ok after 5000 -> error(orphan_coordinator) end,
        {error, {uncertain_inflight, _}} = gen_server:call(Group, {wait, Pid}, infinity),
        ok = gen_server:call(Group, {shutdown, 2000}, infinity),
        reaped = py_nif:actor_ticket_info(Ticket),
        clean = py_nif:context_cleanup_status(Native),
        [] = ets:lookup(py_context_refs, Ctx),
        #{count := 0, bytes := 0, unsettled := 0} = py_nif:actor_gate_info(Gate),
        #{children := []} = gen_server:call(Group, info)
    after gen_server:stop(Group, normal, infinity), py_context:destroy(Source) end.

retained_exception_lifecycle(_) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    ok = py_context:exec(Ctx, iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [Dir]))),
    py_callback:register(task_test_collect, fun([]) ->
        %% Collect this isolated correctness VM's finite BEAM heaps as well as
        %% Python GC; an unreachable resource term may await BEAM collection.
        Pids = processes(),
        true = length(Pids) < 256,
        [erlang:garbage_collect(Pid) || Pid <- Pids],
        ok
    end),
    try
        ok = py_context:start_loop(Ctx),
        {ok, true} = py_context:submit_await(Ctx, py_test_tasks,
            retained_exception_lifecycle, [], #{}, 10000),
        ok = py_context:stop_loop(Ctx)
    after
        py_callback:unregister(task_test_collect),
        py_context:destroy(Ctx)
    end.

wait_ticket(_, 0) -> error(ticket_completion_timeout);
wait_ticket(Ticket, N) ->
    case py_nif:actor_ticket_info(Ticket) of
        complete -> ok;
        _ -> receive after 5 -> wait_ticket(Ticket, N - 1) end
    end.

wait_contexts(_, 0) -> error(orphan_context);
wait_contexts(Baseline, N) ->
    case ets:info(py_context_refs, size) of
        Baseline -> ok;
        _ -> receive after 5 -> wait_contexts(Baseline, N - 1) end
    end.

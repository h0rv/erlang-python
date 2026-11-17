-module(py_tasks_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, killed_child/1,
         killed_context/1, killed_group/1, queued_ticket/1, killed_before_execution/1,
         retained_exception_lifecycle/1, owngil_api/1, owngil_parallel/1,
         owngil_prestart_cancel/1, owngil_running_cancel/1, owngil_killed_context/1,
         owngil_missing_envelope/1, unsupported_named_mode/1, owngil_surrogate_error/1]).
all() -> [killed_child, killed_context, killed_group, queued_ticket, killed_before_execution,
          retained_exception_lifecycle, owngil_api, owngil_parallel,
          owngil_prestart_cancel, owngil_running_cancel, owngil_killed_context,
          owngil_missing_envelope, unsupported_named_mode, owngil_surrogate_error].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    ok = py_import:add_path(filename:dirname(code:which(?MODULE))),
    Config.
end_per_suite(_) -> application:stop(erlang_python).
init_per_testcase(Test, Config) ->
    case lists:prefix("owngil_", atom_to_list(Test)) andalso not py_nif:owngil_supported() of
        true -> {skip, "OWN_GIL requires Python 3.14+"};
        false -> Config
    end.
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
    {ok, Ctx} = py_context:new(#{mode => worker, managed_loop => dedicated}),
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

owngil_api(_) ->
    {ok, Ctx} = py_context:new(#{mode => worker, managed_loop => dedicated}),
    try
        ok = py_context:start_loop(Ctx),
        {ok, true} = py_context:submit_await(Ctx, py_test_task_entries, api, [], #{}, 15000)
    after py_context:destroy(Ctx) end.

owngil_surrogate_error(_) ->
    {ok, Ctx} = py_context:new(#{mode => worker, managed_loop => dedicated}),
    try
        ok = py_context:start_loop(Ctx),
        {ok, true} = py_context:submit_await(Ctx, py_test_task_entries, surrogate_error, [], #{}, 15000)
    after py_context:destroy(Ctx) end.

owngil_parallel(_) ->
    with_named_group(2, fun(Source, Group, Gate) ->
        {ok, Target} = py_context:eval(Source, <<"__import__('time').monotonic_ns() + 2000000000">>),
        Payload = integer_to_binary(Target),
        {ok, A} = start_named(Source, Group, Gate, <<"cpu">>, Payload),
        {ok, B} = start_named(Source, Group, Gate, <<"cpu">>, Payload),
        {ok, {bytes, First}} = gen_server:call(Group, {wait, A}, 10000),
        {ok, {bytes, Second}} = gen_server:call(Group, {wait, B}, 10000),
        [StartA, EndA] = [binary_to_integer(V) || V <- binary:split(First, <<":">>)],
        [StartB, EndB] = [binary_to_integer(V) || V <- binary:split(Second, <<":">>)],
        true = max(StartA, StartB) < min(EndA, EndB),
        #{count := 0, unsettled := 0} = py_nif:actor_gate_info(Gate)
    end).

owngil_prestart_cancel(_) ->
    with_named_group(1, fun(Source, Group, Gate) ->
        {ok, Ticket} = py_context:call(Source, py_test_actor_data, reserve, [Gate, 4]),
        ok = py_nif:actor_ticket_commit(Ticket, Gate, 4),
        #{sup := Sup} = sys:get_state(Group),
        Id = make_ref(),
        Token = erlang:unique_integer([positive]),
        Spec = #{id => Id, start => {py_task, start_link,
            [Group, owngil, {<<"py_test_task_entries">>, <<"must_not_run">>}, Token, Ticket, <<"work">>]},
            restart => temporary, shutdown => infinity},
        {ok, Pid} = supervisor:start_child(Sup, Spec),
        {Ctx, Object, Native} = gen_server:call(Pid, info),
        ok = sys:suspend(Pid),
        _ = sys:replace_state(Group, fun(State) ->
            Mon = monitor(process, Pid),
            Job = #{id => Id, ctx => Ctx, native => Native, object => Object,
                    ticket => Ticket, mon => Mon, result => pending, waiters => [],
                    ready => false, down => false, reaping => false, reaped => false,
                    observed => false, cancel_sent => false, seal_sent => false, sealed => false},
            State#{jobs := #{Pid => Job}}
        end),
        try
            ok = gen_server:call(Group, {cancel, Pid}),
            wait_entry_sealed(Ctx, Token, 100),
            {ok, true} = py_context:submit_await(Ctx, '_erlang_impl._tasks', seal_entry, [Token]),
            committed = py_nif:actor_ticket_info(Ticket),
            #{count := 1, unsettled := 1} = py_nif:actor_gate_info(Gate),
            Pid ! run
        after sys:resume(Pid) end,
        {cancelled} = gen_server:call(Group, {wait, Pid}, 10000),
        complete = py_nif:actor_ticket_info(Ticket),
        clean = py_nif:context_cleanup_status(Native)
    end).

owngil_running_cancel(_) ->
    Parent = self(),
    py_callback:register(task_entry_entered, fun([Payload]) -> Parent ! {entered, Payload}, ok end),
    try with_named_group(1, fun(Source, Group, Gate) ->
        {ok, Pid} = start_named(Source, Group, Gate, <<"waiting">>, <<"work">>),
        receive {entered, <<"work">>} -> ok after 5000 -> error(not_running) end,
        #{count := 1, unsettled := 1} = py_nif:actor_gate_info(Gate),
        ok = gen_server:call(Group, {cancel, Pid}),
        {cancelled} = gen_server:call(Group, {wait, Pid}, 10000),
        #{count := 0, unsettled := 0} = py_nif:actor_gate_info(Gate)
    end) after py_callback:unregister(task_entry_entered) end.

owngil_killed_context(_) ->
    Parent = self(),
    py_callback:register(task_entry_entered, fun([_]) -> Parent ! entered, ok end),
    try with_named_group(1, fun(Source, Group, Gate) ->
        {ok, Pid} = start_named(Source, Group, Gate, <<"waiting">>, <<"work">>),
        receive entered -> ok after 5000 -> error(not_running) end,
        #{jobs := Jobs} = sys:get_state(Group),
        #{ctx := Ctx, native := Native, ticket := Ticket} = maps:get(Pid, Jobs),
        {ok, LoopRef} = py_context:loop_ref(Ctx),
        exit(Ctx, kill),
        {error, {uncertain_inflight, _}} = gen_server:call(Group, {wait, Pid}, 10000),
        {error, {uncertain_inflight, shutdown_deadline}} = gen_server:call(Group, {shutdown, 100}, 5000),
        committed = py_nif:actor_ticket_info(Ticket),
        #{count := 1, unsettled := 1, closed := true} = py_nif:actor_gate_info(Gate),
        {error, _} = py_context:call(Source, py_test_actor_data, reserve, [Gate, 1]),
        %% The context's linked event worker died too. Restore a test-owned
        %% driver solely to clean up this cooperative fixture after assertions.
        {ok, Reaper} = py_event_worker:start_link(<<"task_test_reaper">>, LoopRef),
        try
            ok = py_nif:event_loop_set_worker(LoopRef, Reaper),
            Stop = make_ref(),
            ok = py_nif:submit_task(LoopRef, self(), Stop, <<"erlang">>, <<"_stop_loop">>, [], #{}),
            {ok, <<"stopping">>} = py_event_loop:await(Stop, 5000),
            clean = py_context:reap_dead(Ctx, Native)
        after gen_server:stop(Reaper) end,
        committed = py_nif:actor_ticket_info(Ticket)
    end) after py_callback:unregister(task_entry_entered) end.

owngil_missing_envelope(_) ->
    with_named_group(1, fun(Source, Group, Gate) ->
        {ok, Pid} = start_named(Source, Group, Gate, <<"malformed">>, <<"work">>),
        {error, {uncertain_inflight, _}} = gen_server:call(Group, {wait, Pid}, 10000),
        #{count := 1, unsettled := 1, closed := true} = py_nif:actor_gate_info(Gate),
        {error, {uncertain_inflight, shutdown_deadline}} = gen_server:call(Group, {shutdown, 100}, 5000)
    end).

unsupported_named_mode(_) ->
    with_named_group(1, fun(Source, Group, Gate) ->
        {ok, Ticket} = py_context:call(Source, py_test_actor_data, reserve, [Gate, 4]),
        {error, ticket_not_committed} = py_nif:task_ticket_complete(Ticket),
        reserved = py_nif:actor_ticket_info(Ticket),
        {error, {unsupported_task_mode, isolated}} = gen_server:call(Group,
            {start_named, isolated, Gate, Ticket, <<"work">>, {<<"a">>, <<"b">>}}),
        aborted = py_nif:actor_ticket_info(Ticket),
        {ok, Invalid} = py_context:call(Source, py_test_actor_data, reserve, [Gate, 4]),
        {error, invalid_task_entry} = gen_server:call(Group,
            {start_named, owngil, Gate, Invalid, <<"work">>, {<<"a">>, <<"nested.f">>}}),
        aborted = py_nif:actor_ticket_info(Invalid),
        #{count := 0, unsettled := 0} = py_nif:actor_gate_info(Gate)
    end).

with_named_group(Count, Fun) ->
    {ok, Source} = py_context:new(#{mode => worker}),
    {ok, Group} = py_task_group:start_link(Count, 4096),
    unlink(Group),
    {ok, {Group, Gate}} = gen_server:call(Group, gate),
    try Fun(Source, Group, Gate)
    after gen_server:stop(Group, normal, infinity), py_context:destroy(Source) end.

start_named(Source, Group, Gate, Function, Payload) ->
    {ok, Ticket} = py_context:call(Source, py_test_actor_data, reserve, [Gate, byte_size(Payload)]),
    try gen_server:call(Group, {start_named, owngil, Gate, Ticket, Payload,
                               {<<"py_test_task_entries">>, Function}}, infinity)
    after {ok, none} = py_context:call(Source, py_test_actor_data, abort, [Ticket]) end.

wait_entry_sealed(_, _, 0) -> error(cancellation_not_delivered);
wait_entry_sealed(Ctx, Token, N) ->
    case py_context:submit_await(Ctx, py_test_task_entries, sealed, [Token]) of
        {ok, true} -> ok;
        {ok, false} -> receive after 5 -> wait_entry_sealed(Ctx, Token, N - 1) end
    end.

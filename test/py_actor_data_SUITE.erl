-module(py_actor_data_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         basic/1, cancelled/1, restart/1, ticket_orders/1, busy_kill/1,
         abandoned_commit/1, queued_abort/1, concurrent_children/1, group_kill/1,
         callback_overflow/1, state_graphs/1, resource_release/1, resource_busy_kill/1,
         diagnostic_crash_keeps_siblings_live/1]).
all() -> [basic, cancelled, restart, ticket_orders, busy_kill,
          abandoned_commit, queued_abort, concurrent_children, group_kill, callback_overflow,
          state_graphs, resource_release, resource_busy_kill,
          diagnostic_crash_keeps_siblings_live].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python), Config.
end_per_suite(_) -> application:stop(erlang_python).

with_context(Fun) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    try
        ok = py_context:exec(Ctx, iolist_to_binary(io_lib:format(
            "import sys; sys.path.insert(0, ~p)", [Dir]))),
        Fun(Ctx)
    after py_context:destroy(Ctx) end.

state_graphs(_) -> with_context(fun(Ctx) ->
    {ok, _} = py_context:call(Ctx, test_actor_admission_model,
        test_admission_state_graph, [], #{}),
    {ok, _} = py_context:call(Ctx, test_actor_admission_model,
        test_generation_state_graph, [], #{}),
    {ok, _} = py_context:call(Ctx, test_actor_admission_model,
        test_temporary_lifecycle_graph, [], #{})
end).

basic(_) -> with_context(fun(Ctx) ->
    {ok, true} = py_context:call(Ctx, py_test_actor_data, basic, [], #{}, 10000)
end).

resource_actor(Ctx) ->
    {ok, Factory} = py_context:eval(Ctx,
        <<"__import__('erlang')._actor_retain(__import__('py_test_actor_data').Resource)">>),
    {ok, Group} = py_actor_group:start_link(1),
    unlink(Group),
    {ok, {Actor, Generation, Gate}} = gen_server:call(Group,
        {spawn, <<"resource">>, Factory, 1, 4, <<"temporary">>}, infinity),
    #{object := Object, ctx := Worker} = sys:get_state(Actor),
    {Group, Actor, Generation, Gate, Object, Worker}.

assert_released(Ctx, Object, Worker) ->
    {ok, false} = py_context:call(Ctx, py_test_actor_data, resource_alive, [], #{}),
    {ok, true} = py_context:call(Ctx, py_test_actor_data, reference_released, [Object], #{}),
    ok = py_nif:actor_object_release(Object),
    true = is_process_alive(Worker).

resource_release(_) -> with_context(fun(Ctx) ->
    [begin
        {Group, Actor, Generation, Gate, Object, Worker} = resource_actor(Ctx),
        Ticket = reserve(Ctx, Gate, 1),
        {ok, {ok, {bytes, <<"1">>}}} = py_callback:execute(<<"_actor_data_call">>,
            [Actor, Gate, Ticket, <<"1">>]),
        {ok, true} = py_context:call(Ctx, py_test_actor_data, resource_alive, [], #{}),
        case Mode of
            stop -> {ok, stopped} = gen_server:call(Group, {stop, <<"resource">>}, infinity);
            kill -> {ok, killed} = gen_server:call(Group, {crash, <<"resource">>, Generation}, infinity);
            close -> ok = gen_server:stop(Group, normal, infinity);
            group_kill ->
                Mon = monitor(process, Actor),
                exit(Group, kill),
                receive {'DOWN', Mon, process, Actor, _} -> ok end,
                ok = py_actor_registry:release(Gate)
        end,
        assert_released(Ctx, Object, Worker),
        case is_process_alive(Group) of true -> gen_server:stop(Group); false -> ok end
    end || Mode <- [stop, kill, close, group_kill]]
end).

resource_busy_kill(_) -> with_gate(fun() -> with_context(fun(Ctx) ->
    {Group, Actor, _, Gate, Object, Worker} = resource_actor(Ctx),
    Ticket = reserve(Ctx, Gate, 4),
    Parent = self(),
    spawn(fun() ->
        Result = try py_callback:execute(<<"_actor_data_call">>,
            [Actor, Gate, Ticket, <<"wait">>]) catch exit:Reason -> {exit, Reason} end,
        Parent ! {finished, Result}
    end),
    {ok, _} = py_callback:execute(<<"actor_data_entered">>, []),
    exit(Actor, kill),
    receive {finished, _} -> ok after 5000 -> error(call_survived) end,
    {ok, true} = py_context:call(Ctx, py_test_actor_data, resource_alive, [], #{}),
    {ok, false} = py_context:call(Ctx, py_test_actor_data, reference_released, [Object], #{}),
    {ok, _} = py_callback:execute(<<"actor_data_release">>, []),
    ok = py_actor_registry:release(Gate),
    assert_released(Ctx, Object, Worker),
    gen_server:stop(Group, normal, infinity)
end) end).

cancelled(_) -> with_gate(fun() -> with_context(fun(Ctx) ->
    {ok, true} = py_context:call(Ctx, py_test_actor_data, cancelled, [], #{}, 10000)
end) end).

restart(_) ->
    py_callback:register(actor_data_kill, fun([Pid]) ->
        [{{Group, Id}, Pid, Old, _}] = ets:match_object(py_actor_generations,
            {{'_', '_'}, Pid, '_', '_'}),
        exit(Pid, kill),
        await_generation(Group, Id, Old, 1000)
    end),
    try with_context(fun(Ctx) ->
        {ok, true} = py_context:call(Ctx, py_test_actor_data, restart, [], #{}, 10000)
    end)
    after py_callback:unregister(actor_data_kill) end.

await_generation(_, _, _, 0) -> error(restart_timeout);
await_generation(Group, Id, Old, N) ->
    case gen_server:call(Group, {resolve, Id}) of
        {ok, {_, New, _}} when New =/= Old -> ok;
        _ -> receive after 1 -> await_generation(Group, Id, Old, N - 1) end
    end.

owned(Ctx) ->
    {ok, Factory} = py_context:eval(Ctx,
        <<"__import__('erlang')._actor_retain(__import__('py_test_actor_data').Counter)">>),
    {ok, Group} = py_actor_group:start_link(1),
    unlink(Group),
    {ok, {Actor, Generation, Gate}} = gen_server:call(Group,
        {spawn, <<"counter">>, Factory, 1, 4, <<"permanent">>}, infinity),
    {Group, Actor, Generation, Gate}.

reserve(Ctx, Gate, N) ->
    {ok, Ticket} = py_context:call(Ctx, py_test_actor_data, reserve, [Gate, N], #{}), Ticket.

ticket_orders(_) -> with_context(fun(Ctx) ->
    {Group, Actor, _, Gate} = owned(Ctx),
    try
        Ticket = reserve(Ctx, Gate, 4),
        #{count := 1, bytes := 4} = py_nif:actor_gate_info(Gate),
        {error, _} = py_context:call(Ctx, py_test_actor_data, reserve, [Gate, 1], #{}),
        {ok, _} = py_context:call(Ctx, py_test_actor_data, abort, [Ticket], #{}),
        #{count := 0, bytes := 0} = py_nif:actor_gate_info(Gate),
        {error, ticket_used} = py_nif:actor_ticket_commit(Ticket, Gate, 4),
        Next = reserve(Ctx, Gate, 1),
        {error, ticket_mismatch} = py_nif:actor_ticket_commit(Next, Gate, 2),
        {ok, {ok, {bytes, <<"1">>}}} = py_callback:execute(<<"_actor_data_call">>,
            [Actor, Gate, Next, <<"1">>]),
        #{count := 0, bytes := 0} = py_nif:actor_gate_info(Gate),
        {error, ticket_used} = py_nif:actor_ticket_commit(Next, Gate, 1)
    after gen_server:stop(Group, normal, infinity) end
end).

busy_kill(_) -> with_gate(fun() -> with_context(fun(Ctx) ->
    {Group, Actor, Generation, Gate} = owned(Ctx),
    #{ctx := Worker} = sys:get_state(Actor),
    Ticket = reserve(Ctx, Gate, 4),
    Parent = self(),
    spawn(fun() ->
        Result = try py_callback:execute(<<"_actor_data_call">>,
            [Actor, Gate, Ticket, <<"wait">>]) catch exit:Reason -> {exit, Reason} end,
        Parent ! {finished, Result}
    end),
    {ok, _} = py_callback:execute(<<"actor_data_entered">>, []),
    exit(Actor, kill),
    receive {finished, _} -> ok after 5000 -> error(call_survived) end,
    ActorMon = monitor(process, Actor),
    receive {'DOWN', ActorMon, process, Actor, _} -> ok after 5000 -> error(actor_survived) end,
    true = is_process_alive(Worker),
    #{closed := true, count := 1, bytes := 4} = py_nif:actor_gate_info(Gate),
    %% Supervisor waits for the old body, not the pooled worker's death.
    {error, restarting} = gen_server:call(Group, {resolve, <<"counter">>}),
    {ok, _} = py_callback:execute(<<"actor_data_release">>, []),
    await_generation(Group, <<"counter">>, Generation, 1000),
    true = is_process_alive(Worker),
    Worker = py_worker_pool:checkout(Worker),
    ok = py_worker_pool:checkin(Worker),
    #{closed := true, count := 0, bytes := 0} = py_nif:actor_gate_info(Gate),
    gen_server:stop(Group, normal, infinity),
    [] = ets:lookup(py_actor_generations, {Group, <<"counter">>})
end) end).

concurrent_children(_) -> with_context(fun(Ctx) ->
    {Group, Actor, _, _} = owned(Ctx),
    #{object := Factory} = sys:get_state(Actor),
    %% Use a real factory, not the live state object.
    {ok, Constructor} = py_context:eval(Ctx,
        <<"__import__('erlang')._actor_retain(__import__('py_test_actor_data').Counter)">>),
    true = is_reference(Factory),
    Parent = self(),
    [spawn(fun() -> Parent ! {spawn_result, gen_server:call(Group,
        {spawn, integer_to_binary(N), Constructor, 1, 4, <<"permanent">>}, infinity)} end)
        || N <- lists:seq(1, 16)],
    [receive {spawn_result, {error, max_children}} -> ok
        after 5000 -> error(child_admission_failed) end || _ <- lists:seq(1, 16)],
    {ok, stopped} = gen_server:call(Group, {stop, <<"counter">>}, infinity),
    {ok, {New, _, _}} = gen_server:call(Group,
        {spawn, <<"counter">>, Constructor, 1, 4, <<"permanent">>}, infinity),
    false = Actor =:= New,
    [spawn(fun() ->
        Result = try gen_server:call(Group,
            {spawn, integer_to_binary(N), Constructor, 1, 4, <<"permanent">>}, infinity)
            catch exit:_ -> closed end,
        Parent ! {close_race, Result}
    end) || N <- lists:seq(1, 16)],
    gen_server:stop(Group, normal, infinity),
    [receive {close_race, Result} when Result =:= closed;
               Result =:= {error, max_children} -> ok
        after 5000 -> error(close_race_orphan) end || _ <- lists:seq(1, 16)],
    false = is_process_alive(New)
end).

diagnostic_crash_keeps_siblings_live(_) -> with_context(fun(Ctx) ->
    {ok, Factory} = py_context:eval(Ctx,
        <<"__import__('erlang')._actor_retain(__import__('py_test_actor_data').Counter)">>),
    {ok, Group} = py_actor_group:start_link(2),
    unlink(Group),
    try
        {ok, {Victim, Old, Gate}} = gen_server:call(Group,
            {spawn, <<"victim">>, Factory, 1, 4, <<"permanent">>}),
        {ok, Healthy} = gen_server:call(Group,
            {spawn, <<"healthy">>, Factory, 1, 4, <<"permanent">>}),
        Ticket = reserve(Ctx, Gate, 1),
        ok = py_nif:actor_ticket_commit(Ticket, Gate, 1),
        Mon = monitor(process, Victim),
        Crash = gen_server:send_request(Group, {crash, <<"victim">>, Old}),
        %% Hold the completion acknowledgement past the actor's DOWN.
        %% The healthy actor must answer before the test releases the gate.
        StaleCrash = try
            receive {'DOWN', Mon, process, Victim, killed} -> ok
            after 5000 -> error(victim_survived) end,
            {ok, Healthy} = gen_server:call(Group, {resolve, <<"healthy">>}),
            {HealthyPid, HealthyGeneration, HealthyGate} = Healthy,
            {ok, {{bytes, _}, HealthyGeneration, 0, 0}} = gen_server:call(Group,
                {info, <<"healthy">>, HealthyGeneration}),
            HealthyTicket = reserve(Ctx, HealthyGate, 1),
            {ok, {ok, {bytes, <<"1">>}}} = py_callback:execute(<<"_actor_data_call">>,
                [HealthyPid, HealthyGate, HealthyTicket, <<"1">>]),
            {error, restarting} = gen_server:call(Group, {resolve, <<"victim">>}),
            timeout = gen_server:wait_response(Crash, 0),
            gen_server:send_request(Group, {crash, <<"victim">>, Old})
        after
            {ok, _} = py_context:call(Ctx, erlang, '_actor_complete', [Ticket], #{})
        end,
        {reply, {ok, killed}} = gen_server:receive_response(Crash, 5000),
        {ok, {Replacement, New, NewGate}} = gen_server:call(Group, {resolve, <<"victim">>}),
        true = New > Old,
        false = Replacement =:= Victim,
        {reply, {error, {generation_changed, Old, New}}} =
            gen_server:receive_response(StaleCrash, 5000),
        FreshTicket = reserve(Ctx, NewGate, 1),
        {ok, {ok, {bytes, <<"1">>}}} = py_callback:execute(<<"_actor_data_call">>,
            [Replacement, NewGate, FreshTicket, <<"1">>])
    after gen_server:stop(Group, normal, infinity) end
end).

group_kill(_) -> with_context(fun(Ctx) ->
    {Group, Actor, _, _} = owned(Ctx),
    #{ctx := Worker} = sys:get_state(Actor),
    ActorMon = monitor(process, Actor),
    exit(Group, kill),
    receive {'DOWN', ActorMon, process, Actor, _} -> ok after 5000 -> error(orphan_actor) end,
    true = is_process_alive(Worker),
    %% Synchronize with the registry after its monitor notification.
    registry_empty(Group, 1000)
end).
registry_empty(_, 0) -> error(orphan_registry);
registry_empty(Group, N) ->
    case ets:lookup(py_actor_generations, {Group, <<"counter">>}) of
        [] -> ok;
        _ -> receive after 1 -> registry_empty(Group, N - 1) end
    end.

abandoned_commit(_) -> with_context(fun(Ctx) ->
    {Group, Actor, _, Gate} = owned(Ctx),
    Ticket = reserve(Ctx, Gate, 1),
    ok = sys:suspend(Actor),
    Parent = self(),
    spawn(fun() ->
        Result = try py_callback:execute(<<"_actor_data_call">>,
            [Actor, Gate, Ticket, <<"1">>]) catch exit:Reason -> {exit, Reason} end,
        Parent ! {finished, Result}
    end),
    await_ticket(Ticket, committed, 1000),
    %% The committed call is still in the suspended actor's mailbox.
    exit(Actor, kill),
    receive {finished, {error, {exit, _, _}}} -> ok after 5000 -> error(call_survived) end,
    await_ticket(Ticket, complete, 5000),
    #{unsettled := 0} = py_nif:actor_gate_info(Gate),
    ok = gen_server:stop(Group, normal, 5000)
end).
await_ticket(Ticket, State, 0) -> error({ticket_timeout, State, py_nif:actor_ticket_info(Ticket)});
await_ticket(Ticket, State, N) ->
    case py_nif:actor_ticket_info(Ticket) of
        State -> ok;
        _ -> receive after 1 -> await_ticket(Ticket, State, N - 1) end
    end.

queued_abort(_) -> with_context(fun(Ctx) ->
    {Group, Actor, _, Gate} = owned(Ctx),
    Ticket = reserve(Ctx, Gate, 1),
    ok = sys:suspend(py_thread_handler),
    try
        {ok, _} = py_context:call(Ctx, py_test_actor_data, enqueue,
            [Actor, Gate, Ticket, {bytes, <<"1">>}], #{}),
        {ok, _} = py_context:call(Ctx, py_test_actor_data, abort, [Ticket], #{}),
        %% The LARGE payload is still in the generic callback mailbox. A
        %% caller abort cannot release its bytes or admit another payload.
        #{count := 1, bytes := 1} = py_nif:actor_gate_info(Gate),
        {error, _} = py_context:call(Ctx, py_test_actor_data, reserve, [Gate, 1], #{})
    after sys:resume(py_thread_handler) end,
    wait_empty(Gate, 1000),
    gen_server:stop(Group, normal, infinity)
end).

callback_overflow(_) -> with_context(fun(Ctx) ->
    {Group, Actor, _, Gate} = owned(Ctx),
    Warmup = reserve(Ctx, Gate, 1),
    {ok, _} = py_context:call(Ctx, py_test_actor_data, enqueue,
        [Actor, Gate, Warmup, {bytes, <<"1">>}], #{}),
    wait_empty(Gate, 1000),
    {state, _, Writers, _, _NativeCounter} = sys:get_state(py_thread_handler),
    Counters = [Counter || {_, Counter} <- maps:values(Writers)],
    [wait_counter(Counter, 1000) || Counter <- Counters],
    %% Force the existing generic callback overflow branch without creating
    %% ten thousand unrelated blocked calls. All test callbacks are idle.
    [atomics:put(Counter, 1, 10000) || Counter <- Counters],
    try
        Ticket = reserve(Ctx, Gate, 1),
        {ok, _} = py_context:call(Ctx, py_test_actor_data, enqueue,
            [Actor, Gate, Ticket, {bytes, <<"1">>}], #{}),
        wait_empty(Gate, 1000),
        #{unsettled := 0} = py_nif:actor_gate_info(Gate),
        Read = reserve(Ctx, Gate, 1),
        {ok, {ok, {bytes, <<"1">>}}} = py_callback:execute(<<"_actor_data_call">>,
            [Actor, Gate, Read, <<"0">>])
    after [atomics:put(Counter, 1, 0) || Counter <- Counters],
          gen_server:stop(Group, normal, infinity) end
end).

wait_counter(_, 0) -> error(callback_completion_timeout);
wait_counter(Counter, N) ->
    case atomics:get(Counter, 1) of
        0 -> ok;
        _ -> receive after 1 -> wait_counter(Counter, N - 1) end
    end.

wait_empty(_, 0) -> error(completion_timeout);
wait_empty(Gate, N) ->
    case py_nif:actor_gate_info(Gate) of
        #{count := 0} -> ok;
        _ -> receive after 1 -> wait_empty(Gate, N - 1) end
    end.

with_gate(Fun) ->
    Gate = spawn_link(fun() -> gate([], []) end),
    py_callback:register(actor_data_gate, fun([]) ->
        Gate ! {enter, self()}, receive release -> ok after 5000 -> error(gate_timeout) end
    end),
    py_callback:register(actor_data_entered, fun([]) ->
        Gate ! {wait, self()}, receive entered -> ok after 5000 -> error(entry_timeout) end
    end),
    py_callback:register(actor_data_release, fun([]) -> Gate ! release, ok end),
    py_callback:register(actor_data_join, fun([Actor]) -> sys:get_state(Actor), ok end),
    try Fun() after Gate ! stop,
        [py_callback:unregister(Name) || Name <- [actor_data_gate, actor_data_entered,
                                                actor_data_release, actor_data_join]] end.

gate(Running, Waiting) ->
    receive
        {enter, Pid} -> [P ! entered || P <- Waiting], gate([Pid | Running], []);
        {wait, Pid} when Running =/= [] -> Pid ! entered, gate(Running, Waiting);
        {wait, Pid} -> gate(Running, [Pid | Waiting]);
        release -> [P ! release || P <- Running], gate([], Waiting);
        stop -> [P ! release || P <- Running], ok
    end.

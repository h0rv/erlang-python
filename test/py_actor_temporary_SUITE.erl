-module(py_actor_temporary_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         natural_cycles/1, failed_cycles/1, killed_cycles/1, stale_generation/1,
         busy_actor/1, busy_context/1, unsettled_blocks/1]).

all() -> [natural_cycles, failed_cycles, killed_cycles, stale_generation,
          busy_actor, busy_context, unsettled_blocks].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python), Config.
end_per_suite(_) -> application:stop(erlang_python).

with_group(Fun) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    ok = py_context:exec(Ctx, iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [Dir]))),
    {ok, Factory} = py_context:eval(Ctx,
        <<"__import__('erlang')._actor_retain(__import__('py_test_actor_data').Counter)">>),
    {ok, Group} = py_actor_group:start_link(1),
    unlink(Group),
    try Fun(Ctx, Group, Factory)
    after gen_server:stop(Group, normal, infinity), py_context:destroy(Ctx) end.

child(Group, Factory, Id) ->
    {ok, {Actor, Generation, Gate}} = gen_server:call(Group,
        {spawn, Id, Factory, 1, 4, <<"temporary">>}, infinity),
    [{_, Actor, Generation, Gate, Owned}] = ets:lookup(py_actor_generations, {Group, Id}),
    {Actor, Generation, Gate, Owned}.

reserve(Ctx, Gate, Bytes) ->
    {ok, Ticket} = py_context:call(Ctx, py_test_actor_data, reserve, [Gate, Bytes], #{}),
    Ticket.

natural_cycles(_) -> cycles(normal).
failed_cycles(_) -> cycles(task_failed).
killed_cycles(_) -> cycles(kill).
cycles(Reason) -> with_group(fun(Ctx, Group, Factory) ->
    lists:foldl(fun(N, Previous) ->
        %% Exercise both reused logical IDs and new IDs in the same group.
        Id = case N rem 2 of 0 -> <<"x">>; 1 -> integer_to_binary(N) end,
        {Actor, Generation, Gate, Owned} = child(Group, Factory, Id),
        true = Generation > Previous,
        Ticket = reserve(Ctx, Gate, 1),
        {ok, {ok, {bytes, <<"1">>}}} = py_callback:execute(<<"_actor_data_call">>,
            [Actor, Gate, Ticket, <<"1">>]),
        ActorMon = monitor(process, Actor),
        ContextMon = monitor(process, Owned),
        case Reason of normal -> gen_server:stop(Actor, normal, infinity);
            _ -> exit(Actor, Reason) end,
        down(Actor, ActorMon), down(Owned, ContextMon),
        #{sup := Sup} = sys:get_state(Group),
        [] = supervisor:which_children(Sup),
        %% The NEXT spawn must recover automatically, without group.stop.
        Generation
    end, 0, lists:seq(1, 16)),
    await_empty(Group, 1000),
    {ok, stopped} = gen_server:call(Group, {stop, <<"x">>}),
    {Actor, _, _, Owned} = child(Group, Factory, <<"x">>),
    ActorMon = monitor(process, Actor), ContextMon = monitor(process, Owned),
    %% Explicit stop also copes with OTP deleting its temporary child spec.
    {ok, stopped} = gen_server:call(Group, {stop, <<"x">>}, infinity),
    down(Actor, ActorMon), down(Owned, ContextMon),
    {_, _, _, _} = child(Group, Factory, <<"y">>)
end).

stale_generation(_) -> with_group(fun(_Ctx, Group, Factory) ->
    {Old, Generation, _, Owned} = child(Group, Factory, <<"x">>),
    Mon = monitor(process, Owned),
    exit(Old, kill), down(Owned, Mon),
    {New, Current, Gate, NewCtx} = child(Group, Factory, <<"x">>),
    true = Current > Generation,
    %% The old DOWN and delayed drain check can arrive after ID reuse.
    Group ! {{temporary, <<"x">>, Generation}, make_ref(), process, Old, killed},
    Group ! {reap_temporary, <<"x">>, Generation},
    #{ids := [<<"x">>]} = sys:get_state(Group),
    [{_, New, Current, Gate, NewCtx}] = ets:lookup(py_actor_generations, {Group, <<"x">>}),
    {ok, {New, Current, Gate}} = gen_server:call(Group, {resolve, <<"x">>}),
    blocked(Group, Factory)
end).

busy_actor(_) -> busy(actor).
busy_context(_) -> busy(context).
busy(Victim) -> with_group(fun(Ctx, Group, Factory) ->
    {Actor, _, Gate, Owned} = child(Group, Factory, <<"x">>),
    Parent = self(),
    ok = py_callback:register(actor_data_gate, fun([]) ->
        Parent ! {entered, self()},
        receive release -> ok after 5000 -> error(release_timeout) end
    end),
    try
        Ticket = reserve(Ctx, Gate, 4),
        spawn(fun() ->
            Result = try py_callback:execute(<<"_actor_data_call">>,
                [Actor, Gate, Ticket, <<"wait">>]) catch exit:Reason -> {exit, Reason} end,
            Parent ! {finished, Result}
        end),
        Callback = receive {entered, Pid} -> Pid after 5000 -> error(entry_timeout) end,
        ActorMon = monitor(process, Actor), ContextMon = monitor(process, Owned),
        case Victim of actor -> exit(Actor, kill); context -> exit(Owned, kill) end,
        down(Actor, ActorMon),
        #{sup := Sup} = sys:get_state(Group),
        [] = supervisor:which_children(Sup),
        case Victim of
            actor -> true = is_process_alive(Owned);
            context -> down(Owned, ContextMon)
        end,
        #{unsettled := 1, count := 1} = py_nif:actor_gate_info(Gate),
        blocked(Group, Factory),
        Callback ! release,
        case Victim of actor -> down(Owned, ContextMon); context -> ok end,
        receive {finished, _} -> ok after 5000 -> error(call_survived) end,
        await_empty(Group, 1000),
        #{unsettled := 0, count := 0} = py_nif:actor_gate_info(Gate),
        {_, _, _, _} = child(Group, Factory, <<"y">>)
    after py_callback:unregister(actor_data_gate) end
end).

unsettled_blocks(_) -> with_group(fun(Ctx, Group, Factory) ->
    {Actor, Generation, Gate, Owned} = child(Group, Factory, <<"x">>),
    Ticket = reserve(Ctx, Gate, 1),
    ok = py_nif:actor_ticket_commit(Ticket, Gate, 1),
    Mon = monitor(process, Owned),
    exit(Actor, kill), down(Owned, Mon),
    #{sup := Sup} = sys:get_state(Group),
    [] = supervisor:which_children(Sup),
    %% No Python completion acknowledgment exists yet. Death alone must not
    %% reclaim the slot even after repeated cleanup events and admissions.
    [begin
        Group ! {reap_temporary, <<"x">>, Generation},
        blocked(Group, Factory)
    end || _ <- lists:seq(1, 16)],
    #{unsettled := 1, count := 1, closed := true} = py_nif:actor_gate_info(Gate),
    %% Simulate the eventual native completion acknowledgment, not abandonment.
    {ok, _} = py_context:call(Ctx, erlang, '_actor_complete', [Ticket], #{}),
    await_empty(Group, 1000),
    {_, _, _, _} = child(Group, Factory, <<"x">>)
end).

blocked(Group, Factory) ->
    {error, duplicate_child} = gen_server:call(Group,
        {spawn, <<"x">>, Factory, 1, 4, <<"temporary">>}),
    {error, max_children} = gen_server:call(Group,
        {spawn, <<"y">>, Factory, 1, 4, <<"temporary">>}).

down(Pid, Mon) ->
    receive {'DOWN', Mon, process, Pid, _} -> ok after 5000 -> error(process_survived) end.

await_empty(_, 0) -> error(slot_not_reclaimed);
await_empty(Group, N) ->
    case sys:get_state(Group) of
        #{ids := [], temporary := Temporary} when map_size(Temporary) =:= 0 -> ok;
        _ -> receive after 1 -> await_empty(Group, N - 1) end
    end.

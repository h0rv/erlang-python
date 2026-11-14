-module(py_supervision_tests).
-behaviour(gen_server).
-include_lib("eunit/include/eunit.hrl").
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         runtime/2, ignore/0]).

ignore() -> ignore.
start_link(Mode) -> gen_server:start_link(?MODULE, Mode, []).
init({python, Ctx}) ->
    process_flag(trap_exit, true),
    ok = py:exec(Ctx, <<"value = 0">>),
    {ok, {{python, Ctx}, 0}};
init({fail, Owner}) ->
    Resource = spawn_link(fun() -> receive stop -> ok end end),
    Owner ! {allocated, Resource},
    {stop, startup_failed};
init(fail) -> {stop, startup_failed};
init(Mode) -> process_flag(trap_exit, true), {ok, {Mode, 0}}.
handle_call(incr, _, {{python, Ctx}, _} = S) ->
    ok = py:exec(Ctx, <<"value += 1">>),
    {reply, py:eval(Ctx, <<"value">>), S};
handle_call(value, _, {{python, Ctx}, _} = S) ->
    {reply, py:eval(Ctx, <<"value">>), S};
handle_call(incr, _, {Mode, N}) -> {reply, N + 1, {Mode, N + 1}};
handle_call(value, _, {_, N} = S) -> {reply, N, S}.
handle_cast({finish, Reason}, S) -> {stop, Reason, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, {stubborn, _}) -> receive never -> ok end;
terminate(_, _) -> ok.

sup(Strategy, Budget) ->
    {ok, S} = py_supervision:start_link(#{strategy => Strategy, intensity => Budget, period => 30,
                                            mailbox => unbounded, max_children => unbounded}),
    unlink(S), S.

start(S, Id, Restart, Mode, Deadline) ->
    control([<<"start">>, S, Id, <<"py_supervision_tests">>,
             <<"start_link">>, [Mode], Restart, Deadline, <<"unbounded">>, <<"unbounded">>]).
control(Args) ->
    py_supervision:callback([<<"unbounded">>, <<"unbounded">>, <<"unbounded">> | Args]).
children(S) -> supervisor:which_children(S).
stop(S) -> gen_server:stop(S, shutdown, 2000).
wait(F) -> wait(F, erlang:monotonic_time(millisecond) + 2000).
wait(F, Deadline) ->
    case F() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> receive after 2 -> wait(F, Deadline) end;
                false -> error(deadline)
            end
    end.

admission_fail_closed_test() ->
    S = sup(one_for_one, 3),
    try
        Request = [<<"start">>, S, <<"blocked">>, <<"py_supervision_tests">>,
                   <<"start_link">>, [normal], <<"permanent">>, 20,
                   <<"unbounded">>, <<"unbounded">>],
        ?assertError({capability_unavailable, supervision_admission},
                     py_supervision:callback([128, 65536, <<"unbounded">> | Request])),
        ?assertError({capability_unavailable, supervision_admission},
                     py_supervision:callback(Request)),
        ?assertError({capability_unavailable, supervision_admission},
                     control([<<"start">>, S, <<"blocked-child">>, <<"py_supervision_tests">>,
                              <<"start_link">>, [normal], <<"permanent">>, 20, 128, 65536])),
        ?assertEqual([], children(S)),
        ?assertMatch({error, {capability_unavailable, supervision_admission}},
                     py_supervision:start_link(#{strategy => one_for_one, intensity => 3, period => 5}))
    after stop(S) end.

restart_contract_test_() ->
    [{atom_to_list(Strategy) ++ "/" ++ binary_to_list(Restart) ++ "/" ++ atom_to_list(Reason),
      fun() -> restart_contract(Strategy, Restart, Reason) end} ||
        Strategy <- [one_for_one, one_for_all, rest_for_one],
        Restart <- [<<"permanent">>, <<"transient">>, <<"temporary">>],
        Reason <- [normal, shutdown, failure]].

restart_contract(Strategy, Restart, Reason) ->
    S = sup(Strategy, 20),
    try
        {<<"ok">>, Before} = start(S, <<"before">>, <<"permanent">>, normal, 50),
        {<<"ok">>, P} = start(S, <<"target">>, Restart, normal, 50),
        {<<"ok">>, After} = start(S, <<"after">>, <<"permanent">>, normal, 50),
        ?assertEqual(1, gen_server:call(P, incr)),
        Ref = monitor(process, P),
        gen_server:cast(P, {finish, Reason}),
        receive {'DOWN', Ref, process, P, _} -> ok after 2000 -> error(no_exit) end,
        Expected = Restart =:= <<"permanent">> orelse
                   (Restart =:= <<"transient">> andalso Reason =:= failure),
        wait(fun() ->
            case lists:keyfind(<<"target">>, 1, children(S)) of
                {_, New, _, _} when is_pid(New), New =/= P -> Expected;
                {_, undefined, _, _} -> not Expected;
                false -> not Expected;
                _ -> false
            end
        end),
        Rows = children(S),
        {_, NewBefore, _, _} = lists:keyfind(<<"before">>, 1, Rows),
        {_, NewAfter, _, _} = lists:keyfind(<<"after">>, 1, Rows),
        ?assertEqual(Expected andalso Strategy =:= one_for_all, Before =/= NewBefore),
        ?assertEqual(Expected andalso Strategy =/= one_for_one, After =/= NewAfter),
        case Expected of
            true ->
                {_, NewP, _, _} = lists:keyfind(<<"target">>, 1, Rows),
                ?assertEqual(0, gen_server:call(NewP, value)),
                ?assertNot(is_process_alive(P));
            false -> ok
        end
    after stop(S) end.

storm_test() ->
    S = sup(one_for_one, 1),
    {<<"ok">>, P} = start(S, <<"storm">>, <<"permanent">>, normal, 20),
    Ref = monitor(process, S),
    exit(P, kill),
    wait(fun() ->
        case children(S) of [{_, Next, _, _}] -> is_pid(Next) andalso Next =/= P end
    end),
    [{_, Next, _, _}] = children(S),
    exit(Next, kill),
    receive {'DOWN', Ref, process, S, shutdown} -> ok after 2000 -> error(no_budget_exit) end,
    ?assertNot(is_process_alive(Next)).

temporary_sibling_test_() ->
    [fun() -> temporary_sibling(Strategy) end || Strategy <- [one_for_all, rest_for_one]].
temporary_sibling(Strategy) ->
    S = sup(Strategy, 3),
    try
        {<<"ok">>, P} = start(S, <<"first">>, <<"permanent">>, normal, 20),
        {<<"ok">>, Temporary} = start(S, <<"temporary">>, <<"temporary">>, normal, 20),
        Ref = monitor(process, Temporary),
        gen_server:cast(P, {finish, failure}),
        receive {'DOWN', Ref, process, Temporary, shutdown} -> ok
        after 1000 -> error(temporary_sibling_survived) end,
        wait(fun() ->
            case children(S) of [{_, New, _, _}] -> is_pid(New) andalso New =/= P;
                _ -> false end
        end),
        ?assertEqual(false, lists:keyfind(<<"temporary">>, 1, children(S)))
    after stop(S) end.

budget_window_test() ->
    {ok, S} = py_supervision:start_link(#{strategy => one_for_one, intensity => 1, period => 1,
                                            mailbox => unbounded, max_children => unbounded}),
    unlink(S),
    try
        {<<"ok">>, P} = start(S, <<"worker">>, <<"permanent">>, normal, 20),
        exit(P, kill),
        wait(fun() ->
            case children(S) of [{_, New, _, _}] -> is_pid(New) andalso New =/= P end
        end),
        [{_, Next, _, _}] = children(S),
        receive after 2100 -> ok end,
        exit(Next, kill),
        wait(fun() ->
            case children(S) of [{_, New, _, _}] -> is_pid(New) andalso New =/= Next end
        end),
        ?assert(is_process_alive(S))
    after stop(S) end.

shutdown_test_() ->
    [fun() -> shutdown_case(normal, shutdown) end,
     fun() -> shutdown_case(stubborn, killed) end].
shutdown_case(Mode, Reason) ->
    S = sup(one_for_one, 3),
    try
        {<<"ok">>, P} = start(S, <<"worker">>, <<"permanent">>, Mode, 30),
        Ref = monitor(process, P),
        Start = erlang:monotonic_time(millisecond),
        ?assertEqual({<<"ok">>, undefined}, control([<<"stop">>, S, <<"worker">>])),
        ?assert(erlang:monotonic_time(millisecond) - Start < 1000),
        receive {'DOWN', Ref, process, P, Reason} -> ok after 1000 -> error(no_cleanup) end,
        ?assertEqual([{<<"worker">>, undefined, worker, [py_supervision_tests]}], children(S)),
        {<<"ok">>, New} = control([<<"restart">>, S, <<"worker">>]),
        ?assertNotEqual(P, New),
        ?assertMatch({<<"error">>, running}, control([<<"delete">>, S, <<"worker">>]))
    after stop(S) end.

start_failure_test() ->
    S = sup(one_for_one, 3),
    try
        ?assertMatch({<<"error">>, _}, start(S, <<"bad">>, <<"permanent">>, {fail, self()}, 20)),
        receive {allocated, Resource} ->
            Ref = monitor(process, Resource),
            receive {'DOWN', Ref, process, Resource, _} -> ok
            after 1000 -> error(startup_resource_leaked) end
        after 1000 -> error(no_startup_allocation) end,
        ?assertEqual([], children(S)),
        ?assertMatch({<<"ok">>, _}, start(S, <<"bad">>, <<"permanent">>, normal, 20))
    after stop(S) end.

parent_lifecycle_test() ->
    %% A real OTP parent is used, not a transient callback process.
    Parent = sup(one_for_one, 3),
    {<<"ok">>, ChildSup} = control(
        [<<"start_supervisor">>, Parent, <<"subtree">>, <<"one_for_one">>, 3, 5,
         <<"unbounded">>, <<"unbounded">>, <<"unbounded">>]),
    {<<"ok">>, Worker} = start(ChildSup, <<"worker">>, <<"permanent">>, normal, 20),
    Ref = monitor(process, Worker),
    stop(Parent),
    receive {'DOWN', Ref, process, Worker, shutdown} -> ok after 2000 -> error(orphan) end,
    ?assertNot(is_process_alive(ChildSup)).

runtime(Source, Tests) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    {ok, Ctx} = py_context:new(#{mode => worker}),
    S = sup(one_for_one, 3),
    try
        {<<"ok">>, P} = start(S, <<"python">>, <<"permanent">>, {python, Ctx}, 100),
        ?assertEqual({ok, 1}, gen_server:call(P, incr)),
        exit(P, kill),
        wait(fun() ->
            case children(S) of [{_, New, _, _}] -> is_pid(New) andalso New =/= P end
        end),
        [{_, New, _, _}] = children(S),
        ?assertEqual({ok, 0}, gen_server:call(New, value)),
        ?assertEqual({ok, 1}, gen_server:call(New, incr))
    after stop(S) end,
    ok = py:exec(Ctx, iolist_to_binary(io_lib:format(
        "import sys; sys.path[:0] = [~p, ~p]", [Source, Tests]))),
    py_callback:register('_supervision_test_finish', fun([Pid, Reason]) ->
        gen_server:cast(Pid, {finish, binary_to_existing_atom(Reason)}), ok
    end),
    Parent = sup(one_for_one, 3),
    try
        ok = py_context:start_loop(Ctx),
        ?assertEqual({ok, true}, py_context:submit_await(
            Ctx, supervision_probe, exercise, [Parent], #{}, 10000)),
        ok = py_context:stop_loop(Ctx)
    after
        stop(Parent),
        py_context:stop(Ctx)
    end,
    ok.


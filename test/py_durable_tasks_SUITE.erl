-module(py_durable_tasks_SUITE).
-export([all/0, suite/0, init_per_suite/1, end_per_suite/1,
         replicated_queue/1, replica_options/1, remote_sync_failure/1, task_contract/1,
         worker_restart/1, node_recovery/1, full_recovery/1, boot/1, watch/2]).

suite() -> [{timetrap, {seconds, 180}}].
all() -> [replicated_queue, replica_options, remote_sync_failure, task_contract,
          worker_restart, node_recovery, full_recovery].
init_per_suite(C) ->
    case node() of
        nonode@nohost ->
            os:cmd("epmd -daemon"),
            {ok, _} = net_kernel:start([durable_tasks_ct, shortnames]);
        _ -> ok
    end,
    C.
end_per_suite(_) -> ok.

boot(TestDir) ->
    application:load(erlang_python),
    application:set_env(erlang_python, num_contexts, 1),
    application:set_env(erlang_python, event_loop_pool_size, 1),
    {ok, _} = application:ensure_all_started(erlang_python),
    ok = py_import:add_path(TestDir).

watch(Parent, Queue) ->
    py_callback:register(durable_test_info, fun([Payload]) ->
        Items = mnesia:dirty_match_object({dq_item, '_', Queue, '_', '_', '_', '_', '_'}),
        [Item] = [J || J <- Items,
                      element(5, J) =:= term_to_binary(
                        {durable_task, 1, <<"py_test_durable_tasks">>, <<"run">>, Payload})],
        #{<<"id">> := Id} = json:decode(Payload),
        Attempt = element(6, Item),
        Parent ! {started, node(), Id, Attempt},
        {atom_to_binary(node()), Attempt}
    end).

replicated_queue(C) -> with_cluster(C, fun(Peers, _, _) ->
    [A, _, Z] = Peers, Q = <<"q">>, Parent = self(),
    spawn(fun() -> Parent ! {claim, call(Z, py_durable_queue, claim, [Q, 10000, 5000])} end),
    receive {claim, _} -> error(did_not_block) after 50 -> ok end,
    {ok, stored} = call(A, py_durable_queue, put, [Q, <<"key">>, <<"remote">>]),
    receive {claim, {ok, Id, Token, 1, <<"remote">>}} ->
        ok = call(A, py_durable_queue, ack, [Id, Token])
    after 6000 -> error(remote_waiter_not_woken) end,
    empty = call(Z, py_durable_queue, claim, [Q, 1000, 0]),
    {ok, stored} = call(Z, py_durable_queue, put, [Q, <<"key">>, <<"again">>]),
    {ok, _, _, 1, <<"again">>} = call(A, py_durable_queue, claim, [Q, 1000, 0])
end).

replica_options(C) -> with_cluster(C, fun([A | _], Nodes, Dirs) ->
    {error, _} = call(A, py_durable_queue, open, [hd(Dirs), <<"other">>, 100, []]),
    {error, _} = call(A, py_durable_queue, open, [<<"/wrong-dir">>, <<"q">>, 100, Nodes]),
    {error, local_replica_required} = call(A, py_durable_queue, open,
        [hd(Dirs), <<"other">>, 100, [<<"not-a-local-node@localhost">>]]),
    {error, invalid_argument} = call(A, py_durable_queue, open, [hd(Dirs), <<"q">>, 100, [1]]),
    ok = call(A, py_durable_queue, open, [hd(Dirs), <<"q">>, 100, lists:reverse(Nodes)])
end).

remote_sync_failure(C) -> with_cluster(C, fun([A, B, _], _, _) ->
    ok = call(B, sys, suspend, [py_durable_queue_sync]),
    try
        {error, {sync_failed, _}} = call(A, py_durable_queue, put, [<<"q">>, undefined, <<"uncertain">>])
    after call(B, sys, resume, [py_durable_queue_sync]) end
end).

task_contract(C) -> with_cluster(C, fun([A | _], _, _) ->
    Q = <<"q">>, M = <<"py_test_durable_tasks">>,
    {error, not_open} = call(A, py_durable_tasks, serve, [<<"closed">>, 1, 1000]),
    {error, invalid_argument} = call(A, py_durable_tasks, serve, [Q, 0, 1000]),
    {error, invalid_argument} = call(A, py_durable_tasks, submit, [Q, undefined, <<>>, <<"echo">>, <<>>]),
    {error, payload_too_large} = call(A, py_durable_tasks, submit,
        [Q, undefined, M, <<"echo">>, binary:copy(<<0>>, 1048576)]),
    {ok, stored} = call(A, py_durable_tasks, submit, [Q, <<"key">>, M, <<"echo">>, <<>>]),
    {ok, duplicate} = call(A, py_durable_tasks, submit, [Q, <<"key">>, M, <<"echo">>, <<>>]),
    ok = call(A, py_durable_tasks, serve, [Q, 1, 1000]),
    {error, already_serving} = call(A, py_durable_tasks, serve, [Q, 1, 1000]),
    await_empty(A),
    ok = call(A, py_durable_tasks, stop, [Q]),
    ok = call(A, py_durable_tasks, stop, [Q]),
    [begin
        {ok, stored} = call(A, py_durable_tasks, submit, [Q, undefined, M, F, <<>>]),
        ok = call(A, py_durable_tasks, serve, [Q, 1, 1000]),
        wait(fun() -> lists:any(fun(J) -> element(6, J) >= 2 end, items(A)) end, 5000),
        ok = call(A, py_durable_tasks, stop, [Q]),
        {ok, Id, Token, _, _} = call(A, py_durable_queue, claim, [Q, 1000, 2000]),
        ok = call(A, py_durable_queue, ack, [Id, Token])
     end || F <- [<<"fail">>, <<"wrong_result">>, <<"missing_function">>]],
    {ok, stored} = call(A, py_durable_tasks, submit, [Q, undefined, <<"no_such_module">>, <<"f">>, <<>>]),
    ok = call(A, py_durable_tasks, serve, [Q, 1, 1000]),
    wait(fun() -> lists:any(fun(J) -> element(6, J) >= 2 end, items(A)) end, 5000),
    ok = call(A, py_durable_tasks, stop, [Q])
end).

worker_restart(C) -> with_cluster(C, fun([A | _], _, _) ->
    Path = output(C), Q = <<"q">>,
    submit(A, Path, 1),
    ok = call(A, py_durable_tasks, serve, [Q, 1, 1000]),
    started(1),
    [{Q, Pool, supervisor, _}] = call(A, supervisor, which_children, [py_durable_tasks]),
    [{1, Worker, _, _}] = call(A, supervisor, which_children, [Pool]),
    Store = call(A, erlang, whereis, [py_durable_queue]),
    true = call(A, erlang, exit, [Worker, kill]),
    wait(fun() ->
        [{1, New, _, _}] = call(A, supervisor, which_children, [Pool]),
        is_pid(New) andalso New =/= Worker
    end, 5000),
    Store = call(A, erlang, whereis, [py_durable_queue]),
    await_empty(A),
    ok = call(A, py_durable_tasks, stop, [Q]),
    submit(A, Path, 2),
    ok = call(A, py_durable_tasks, serve, [Q, 1, 10000]),
    started(2),
    ok = call(A, py_durable_tasks, stop, [Q]),
    {ok, Id, Token, 2, _} = call(A, py_durable_queue, claim, [Q, 1000, 2000]),
    ok = call(A, py_durable_queue, ack, [Id, Token])
end).

node_recovery(C) -> with_cluster(C, fun(Peers, Nodes, Dirs) ->
    [A, B, Dead] = Peers, Path = output(C),
    [submit(A, Path, I) || I <- lists:seq(1, 30)],
    [ok = call(P, py_durable_tasks, serve, [<<"q">>, 2, 1500]) || P <- Peers],
    Held = started_on(element(2, Dead), 2, []),
    kill_peer(Dead),
    await_empty(A),
    assert_completed(Path, lists:seq(1, 30)),
    assert_retried(A, Path, Held),
    Restarted = start_peer(element(3, Dead)),
    try
        open_peers([Restarted], Nodes, [lists:nth(3, Dirs)]),
        [] = items(Restarted),
        submit(Restarted, Path, 31),
        await_empty(B),
        assert_completed(Path, lists:seq(1, 31))
    after stop_peer(Restarted) end
end).

full_recovery(C) -> with_cluster(C, fun(Peers, Nodes, Dirs) ->
    [A | _] = Peers, Path = output(C),
    [submit(A, Path, I) || I <- lists:seq(1, 30)],
    [ok = call(P, py_durable_tasks, serve, [<<"q">>, 2, 1500]) || P <- Peers],
    [started_on(element(2, P), 2, []) || P <- Peers],
    Pending = [element(2, J) || J <- items(A)],
    true = length(Pending) > 0,
    [kill_peer(P) || P <- Peers],
    Again = [start_peer(element(3, P)) || P <- Peers],
    try
        open_peers(Again, Nodes, Dirs),
        Recovered = [element(2, J) || J <- items(hd(Again))],
        true = lists:all(fun(Id) -> lists:member(Id, Recovered) end, Pending),
        [ok = call(P, py_durable_tasks, serve, [<<"q">>, 2, 1500]) || P <- Again],
        await_empty(hd(Again)),
        assert_completed(Path, lists:seq(1, 30))
    after [stop_peer(P) || P <- Again] end
end).

with_cluster(C, Fun) ->
    flush_started(),
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Names = [list_to_atom("dt" ++ integer_to_list(I) ++ "_" ++ Suffix) || I <- lists:seq(1, 3)],
    Peers = [start_peer(N) || N <- Names],
    Nodes = [atom_to_binary(N) || {_, N, _} <- Peers],
    Root = proplists:get_value(priv_dir, C),
    Dirs = [unicode:characters_to_binary(filename:join(Root, atom_to_list(N))) || N <- Names],
    try
        open_peers(Peers, Nodes, Dirs),
        Fun(Peers, Nodes, Dirs)
    after [stop_peer(P) || P <- Peers] end.

start_peer(Name) ->
    Paths = lists:append([["-pa", filename:absname(P)] || P <- code:get_path()]),
    {ok, P, N} = peer:start(#{name => Name, connection => standard_io,
        args => ["+S", "2:2", "+A", "2", "-setcookie", atom_to_list(erlang:get_cookie()) | Paths]}),
    Peer = {P, N, Name},
    ok = call(Peer, ?MODULE, boot, [filename:dirname(code:which(?MODULE))]),
    Peer.
open_peers(Peers, Nodes, Dirs) ->
    Parent = self(),
    Refs = [begin
        Ref = make_ref(),
        spawn(fun() ->
            Result = try call(P, py_durable_queue, open, [D, <<"q">>, 100, Nodes])
                     catch Class:Reason -> {Class, Reason} end,
            Parent ! {Ref, Result}
        end),
        {Ref, P}
    end || {P, D} <- lists:zip(Peers, Dirs)],
    [receive {Ref, R} ->
        case R of ok -> ok; _ -> error({open_failed, P, R}) end
     after 65000 -> error(open_timeout) end || {Ref, P} <- Refs],
    [ok = call(P, ?MODULE, watch, [self(), <<"q">>]) || P <- Peers], ok.
call({P, _, _}, Module, Function, Args) -> peer:call(P, Module, Function, Args, 65000).
stop_peer({P, _, _}) -> try peer:stop(P) catch _:_ -> ok end, ok.
kill_peer(Peer = {P, _, _}) ->
    Pid = call(Peer, os, getpid, []), Mon = monitor(process, P),
    os:cmd("kill -9 " ++ Pid),
    receive {'DOWN', Mon, process, P, _} -> ok after 10000 -> error(kill_timeout) end.
items(P) -> call(P, mnesia, dirty_match_object, [{dq_item, '_', <<"q">>, '_', '_', '_', '_', '_'}]).
await_empty(P) -> wait(fun() -> items(P) =:= [] end, 30000).
submit(P, Path, Id) ->
    Payload = iolist_to_binary(json:encode(#{id => Id, path => Path})),
    {ok, stored} = call(P, py_durable_tasks, submit,
        [<<"q">>, integer_to_binary(Id), <<"py_test_durable_tasks">>, <<"run">>, Payload]).
output(C) -> unicode:characters_to_binary(filename:join(proplists:get_value(priv_dir, C),
    "completed-" ++ integer_to_list(erlang:unique_integer([positive])))).
started(Id) -> receive {started, _, Id, _} -> ok after 5000 -> error({not_started, Id}) end.
started_on(_, 0, Acc) -> Acc;
started_on(Node, N, Acc) ->
    receive {started, Node, Id, Attempt} -> started_on(Node, N-1, [{Id, Attempt} | Acc])
    after 5000 -> error({no_leases, Node}) end.
flush_started() -> receive {started, _, _, _} -> flush_started() after 0 -> ok end.
completed(Path) ->
    {ok, Bytes} = file:read_file(Path),
    [begin [Id, Node, Attempt] = binary:split(Line, <<" ">>, [global]),
        {binary_to_integer(Id), Node, binary_to_integer(Attempt)} end ||
        Line <- binary:split(Bytes, <<"\n">>, [global]), Line =/= <<>>].
assert_completed(Path, Ids) ->
    Ids = lists:usort([I || {I, _, _} <- completed(Path)]), ok.
assert_retried(_, Path, Held) ->
    Rows = completed(Path),
    [true = lists:any(fun({I, _, A}) -> I =:= Id andalso A > Old end, Rows) || {Id, Old} <- Held], ok.
wait(F, Millis) -> wait_until(F, erlang:monotonic_time(millisecond) + Millis).
wait_until(F, Deadline) ->
    case F() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(20), wait_until(F, Deadline);
                false -> error(condition_timeout)
            end
    end.

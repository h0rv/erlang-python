-module(py_actor_failover_SUITE).
-export([all/0, suite/0, init_per_suite/1, end_per_suite/1,
         replica_options/1, node_failover/1, boot/0, start_claim/3]).

suite() -> [{timetrap, {seconds, 180}}].
all() -> [replica_options, node_failover].
init_per_suite(C) ->
    case node() of
        nonode@nohost ->
            os:cmd("epmd -daemon"),
            {ok, _} = net_kernel:start([actor_failover_ct, shortnames]);
        _ -> ok
    end,
    C.
end_per_suite(_) -> ok.

boot() ->
    application:load(erlang_python),
    application:set_env(erlang_python, num_contexts, 1),
    application:set_env(erlang_python, event_loop_pool_size, 1),
    {ok, _} = application:ensure_all_started(erlang_python), ok.

replica_options(C) -> cluster(C, fun([A | _], Nodes, [Dir | _]) ->
    [begin
        true = call(A, mnesia, table_info, [T, majority]),
        Disc = call(A, mnesia, table_info, [T, disc_copies]),
        Nodes = lists:sort([atom_to_binary(N) || N <- Disc])
     end || T <- [py_actor_snapshot, py_actor_owner, py_actor_state_meta]],
    {error, at_least_three_replicas_required} = call(A, py_actor_state, open,
        [Dir, lists:sublist(Nodes, 2)]),
    {error, at_least_three_replicas_required} = call(A, py_actor_state, open, [Dir, [hd(Nodes)]]),
    {error, invalid_argument} = call(A, py_actor_state, open, [Dir, [1]]),
    {error, _} = call(A, py_actor_state, open, [Dir, []]),
    ok = call(A, py_actor_state, open, [Dir, lists:reverse(Nodes)])
end).

node_failover(C) -> cluster(C, fun([A, B, Z], _, _) ->
    Key = <<"survivor">>,
    {ok, Token} = call(A, py_actor_state, claim, [Key, <<"first">>]),
    {ok, 1} = call(A, py_actor_state, write, [Key, 0, <<"saved">>, Token]),
    ok = call(B, ?MODULE, start_claim, [self(), Key, <<"B">>]),
    ok = call(Z, ?MODULE, start_claim, [self(), Key, <<"C">>]),
    assert_waiting(B, <<"B">>), assert_waiting(Z, <<"C">>),
    kill_peer(A),
    {Winner, WonRef, Next} = receive
        {claimed, Node, Ref, {ok, T}} ->
            Peer = case Node of NB when NB =:= element(2, B) -> B; _ -> Z end,
            {Peer, Ref, T}
    after 15000 -> error(no_failover) end,
    {ok, 1, <<"saved">>} = call(Winner, py_actor_state, read, [Key]),
    {error, not_owner} = call(Winner, py_actor_state, write, [Key, 1, <<"stale">>, Token]),
    {ok, 2} = call(Winner, py_actor_state, write, [Key, 1, <<"fresh">>, Next]),
    {Loser, LostRef} = case WonRef of <<"B">> -> {Z, <<"C">>}; _ -> {B, <<"B">>} end,
    waiting_state(Loser, LostRef),
    receive {claimed, _, _, _} -> error(two_owners) after 0 -> ok end,
    ok = call(Winner, py_actor_state, release, [Next]),
    receive {claimed, _, LostRef, {ok, Last}} ->
        ok = call(Loser, py_actor_state, release, [Last])
    after 5000 -> error(loser_not_woken) end
end).

start_claim(Parent, Key, Ref) ->
    spawn(fun() ->
        py_actor_state_owner ! {'$gen_call', {self(), Ref}, {claim, Key, Ref}},
        _ = sys:get_state(py_actor_state_owner),
        Parent ! {queued, node(), Ref},
        receive {Ref, Result} -> Parent ! {claimed, node(), Ref, Result} end
    end), ok.

assert_waiting(Peer, Ref) ->
    %% The snapshot is taken after the remote caller has enqueued its claim.
    Node = element(2, Peer),
    receive {queued, Node, Ref} -> ok after 5000 -> error(not_queued) end,
    waiting_state(Peer, Ref).

waiting_state(Peer, Ref) ->
    #{claims := Claims} = call(Peer, sys, get_state, [py_actor_state_owner]),
    #{status := waiting} = maps:get(Ref, Claims), ok.

cluster(C, Fun) ->
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Names = [list_to_atom("as" ++ integer_to_list(I) ++ "_" ++ Suffix) || I <- lists:seq(1, 3)],
    Peers = [start_peer(N) || N <- Names],
    Nodes = [atom_to_binary(N) || {_, N} <- Peers],
    Root = proplists:get_value(priv_dir, C),
    Dirs = [unicode:characters_to_binary(filename:join(Root, atom_to_list(N))) || N <- Names],
    try
        Parent = self(),
        Refs = [begin
            Ref = make_ref(),
            spawn(fun() -> Parent ! {Ref, call(P, py_actor_state, open, [D, Nodes])} end),
            Ref
        end || {P, D} <- lists:zip(Peers, Dirs)],
        [receive {Ref, ok} -> ok; {Ref, Error} -> error({open_failed, Error})
         after 65000 -> error(open_timeout) end || Ref <- Refs],
        Fun(Peers, Nodes, Dirs)
    after [stop_peer(P) || P <- Peers] end.

start_peer(Name) ->
    Paths = lists:append([["-pa", filename:absname(P)] || P <- code:get_path()]),
    {ok, P, N} = peer:start(#{name => Name, connection => standard_io,
        args => ["+S", "2:2", "+A", "2", "-setcookie", atom_to_list(erlang:get_cookie()) | Paths]}),
    Peer = {P, N}, ok = call(Peer, ?MODULE, boot, []), Peer.
call({P, _}, M, F, A) -> peer:call(P, M, F, A, 65000).
stop_peer({P, _}) -> try peer:stop(P) catch _:_ -> ok end, ok.
kill_peer(Peer = {P, _}) ->
    OsPid = call(Peer, os, getpid, []), Mon = monitor(process, P),
    os:cmd("kill -9 " ++ OsPid),
    receive {'DOWN', Mon, process, P, _} -> ok after 10000 -> error(kill_timeout) end.

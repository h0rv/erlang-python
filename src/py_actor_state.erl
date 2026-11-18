%%% @doc Owned, versioned actor snapshots with explicit log-synced writes.
-module(py_actor_state).
-export([register_callbacks/0, open/1, open/2, read/1, write/4,
         claim/2, cancel/1, release/1]).
-record(py_actor_snapshot, {key, version, payload}).
-record(py_actor_owner, {key, node, pid, token}).
-record(py_actor_state_meta, {key, value}).

register_callbacks() ->
    py_callback:register('_actor_state_open', fun
        ([Dir]) -> open(Dir);
        ([Dir, Replicas]) -> open(Dir, Replicas)
    end),
    py_callback:register('_actor_state_claim', fun([Key, Ref]) ->
        case claim(Key, Ref) of
            {ok, Token} -> {ok, {bytes, Token}};
            Other -> Other
        end
    end),
    py_callback:register('_actor_state_cancel', fun([Ref]) -> cancel(Ref) end),
    py_callback:register('_actor_state_release', fun([Token]) -> release(Token) end),
    py_callback:register('_actor_state_read', fun([Key]) ->
        case read(Key) of
            {ok, Version, Payload} -> {ok, Version, {bytes, Payload}};
            Other -> Other
        end
    end),
    py_callback:register('_actor_state_write', fun([Key, Version, Payload, Token]) ->
        write(Key, Version, Payload, Token)
    end), ok.

open(Dir) -> open(Dir, []).
open(Dir, Replicas) when is_binary(Dir), byte_size(Dir) > 0, is_list(Replicas) ->
    case lists:all(fun(N) -> is_binary(N) andalso byte_size(N) > 0 end, Replicas) of
        false -> {error, invalid_argument};
        true ->
            Nodes = lists:usort([binary_to_atom(N, utf8) || N <- Replicas]),
            case {Nodes, length(Nodes), lists:member(node(), Nodes)} of
                {[], _, _} -> open_nodes(Dir, [node()]);
                {_, N, _} when N < 3 -> {error, at_least_three_replicas_required};
                {_, _, false} -> {error, local_replica_required};
                _ -> open_nodes(Dir, Nodes)
            end
    end;
open(_, _) -> {error, invalid_argument}.

open_nodes(Dir, Nodes) ->
    protect(fun() ->
        ok = py_mnesia:ensure_store(filename:absname(unicode:characters_to_list(Dir)),
            Nodes, tables(), py_actor_state_meta, ?MODULE, whereis(py_actor_state_owner)),
        ok = gen_server:call(py_actor_state_owner, opened, infinity),
        mnesia:sync_log()
    end).

claim(Key, Ref) when is_binary(Key), byte_size(Key) > 0, byte_size(Key) =< 4096,
                     is_binary(Ref), byte_size(Ref) > 0, byte_size(Ref) =< 4096 ->
    gen_server:call(py_actor_state_owner, {claim, Key, Ref}, infinity);
claim(_, _) -> {error, invalid_argument}.
cancel(Ref) when is_binary(Ref), byte_size(Ref) > 0, byte_size(Ref) =< 4096 ->
    gen_server:call(py_actor_state_owner, {cancel, Ref}, infinity);
cancel(_) -> {error, invalid_argument}.
release(Token) when is_binary(Token) ->
    gen_server:call(py_actor_state_owner, {release, Token}, infinity);
release(_) -> {error, invalid_argument}.

read(Key) when is_binary(Key), byte_size(Key) > 0, byte_size(Key) =< 4096 ->
    protect(fun() ->
        transaction(fun() ->
            case mnesia:read(py_actor_snapshot, Key, read) of
                [] -> missing;
                [#py_actor_snapshot{version = Version, payload = Payload}] ->
                    {ok, Version, Payload}
            end
        end)
    end);
read(_) -> {error, invalid_argument}.

write(Key, Expected, Payload, Token)
  when is_binary(Key), byte_size(Key) > 0, byte_size(Key) =< 4096,
       is_integer(Expected), Expected >= 0, is_binary(Payload), byte_size(Payload) =< 1048576,
       is_binary(Token) ->
    protect(fun() ->
        ok = py_mnesia:symmetric_tables(persistent_term:get({?MODULE, replicas}), tables()),
        Result = transaction(fun() ->
            case mnesia:read(py_actor_owner, Key, read) of
                [#py_actor_owner{token = Token}] -> ok;
                _ -> mnesia:abort(not_owner)
            end,
            Current = case mnesia:read(py_actor_snapshot, Key, write) of
                [] -> 0;
                [#py_actor_snapshot{version = Version}] -> Version
            end,
            case Current =:= Expected of
                true ->
                    Next = Current + 1,
                    mnesia:write(#py_actor_snapshot{key = Key, version = Next, payload = Payload}),
                    {ok, Next};
                false -> mnesia:abort({version_conflict, Expected, Current})
            end
        end),
        case Result of
            {ok, _} -> ok = mnesia:sync_log(), Result;
            _ -> Result
        end
    end);
write(_, _, _, _) -> {error, invalid_argument}.

tables() ->
    [{py_actor_snapshot, record_info(fields, py_actor_snapshot), true},
     {py_actor_owner, record_info(fields, py_actor_owner), true},
     {py_actor_state_meta, record_info(fields, py_actor_state_meta), true}].

transaction(Fun) ->
    case mnesia:sync_transaction(Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

protect(Fun) ->
    try Fun() catch Class:Reason -> {error, {store_failed, Class, Reason}} end.

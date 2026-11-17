%%% @doc Versioned local-disk actor snapshots with explicit log-synced writes.
-module(py_actor_state).
-export([register_callbacks/0, open/1, read/1, write/3]).
-record(py_actor_snapshot, {key, version, payload}).

register_callbacks() ->
    py_callback:register('_actor_state_open', fun([Dir]) -> open(Dir) end),
    py_callback:register('_actor_state_read', fun([Key]) ->
        case read(Key) of
            {ok, Version, Payload} -> {ok, Version, {bytes, Payload}};
            Other -> Other
        end
    end),
    py_callback:register('_actor_state_write', fun([Key, Version, Payload]) ->
        write(Key, Version, Payload)
    end), ok.

open(Dir) when is_binary(Dir), byte_size(Dir) > 0 ->
    protect(fun() ->
        ok = py_mnesia:ensure_started(filename:absname(unicode:characters_to_list(Dir)), true),
        case mnesia:create_table(py_actor_snapshot,
                [{attributes, record_info(fields, py_actor_snapshot)},
                 {disc_copies, [node()]}, {majority, true}]) of
            {atomic, ok} -> ok;
            {aborted, {already_exists, py_actor_snapshot}} -> ok;
            Error -> error({table, Error})
        end,
        ok = mnesia:wait_for_tables([py_actor_snapshot], 30000),
        ok = local_disk(),
        ok = mnesia:sync_log()
    end);
open(_) -> {error, invalid_argument}.

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

write(Key, Expected, Payload)
  when is_binary(Key), byte_size(Key) > 0, byte_size(Key) =< 4096,
       is_integer(Expected), Expected >= 0, is_binary(Payload), byte_size(Payload) =< 1048576 ->
    protect(fun() ->
        ok = local_disk(),
        Result = transaction(fun() ->
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
write(_, _, _) -> {error, invalid_argument}.

local_disk() ->
    case {mnesia:table_info(py_actor_snapshot, disc_copies),
          mnesia:table_info(py_actor_snapshot, ram_copies),
          mnesia:table_info(py_actor_snapshot, disc_only_copies)} of
        {[Node], [], []} when Node =:= node() -> ok;
        _ -> error(unsupported_snapshot_layout)
    end.

transaction(Fun) ->
    case mnesia:sync_transaction(Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

protect(Fun) ->
    try Fun() catch Class:Reason -> {error, {store_failed, Class, Reason}} end.

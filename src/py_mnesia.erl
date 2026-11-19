%%% @doc Directory-checked Mnesia startup shared by durable runtime services.
-module(py_mnesia).
-export([ensure_started/2, ensure_store/6, symmetric_tables/2, start_link/0]).

start_link() ->
    case pg:start_link(py_mnesia_pg) of
        {error, {already_started, Pid}} -> link(Pid), {ok, Pid};
        Result -> Result
    end.

ensure_store(Dir, Nodes, Tables, Meta, Namespace, Holder) ->
    case persistent_term:get({Namespace, replicas}, Nodes) of
        Nodes -> ok;
        _ -> error(replica_set_mismatch)
    end,
    Seed = hd(Nodes),
    case Nodes of
        [_] -> ok;
        _ ->
            case whereis(py_mnesia_pg) of
                undefined -> {ok, Scope} = start_link(), unlink(Scope);
                _ -> ok
            end
    end,
    ok = ensure_started(Dir, node() =:= Seed),
    case mnesia:subscribe({table, schema, simple}) of
        {ok, _} -> ok;
        {error, {already_exists, _}} -> ok
    end,
    try
        [net_kernel:connect_node(N) || N <- Nodes, N =/= node()],
        {ok, _} = mnesia:change_config(extra_db_nodes, Nodes -- [node()]),
        Deadline = erlang:monotonic_time(millisecond) + 30000,
        Names = [T || {T, _, _} <- Tables],
        case {Names -- mnesia:system_info(local_tables), node() =:= Seed} of
            {[], false} ->
                ok = mnesia:wait_for_tables(Names, 30000),
                check_replicas(Meta, Nodes, false);
            {_, true} ->
                [case mnesia:create_table(T, [{attributes, Attrs}, {type, ordered_set},
                        {disc_copies, [node()]}, {majority, Majority andalso T =/= Meta}]) of
                    {atomic, ok} -> ok;
                    {aborted, {already_exists, T}} -> ok;
                    Error -> error({table, Error})
                 end || {T, Attrs, Majority} <- Tables],
                ok = mnesia:wait_for_tables(Names, 30000),
                check_replicas(Meta, Nodes, true),
                case Nodes of
                    [_] -> ok;
                    _ ->
                        Group = {?MODULE, Meta, Nodes},
                        case lists:member(Holder, pg:get_local_members(py_mnesia_pg, Group)) of
                            true -> ok;
                            false -> ok = pg:join(py_mnesia_pg, Group, Holder)
                        end
                end;
            {_, false} ->
                await_seed(Seed, Meta, Nodes, Deadline),
                {ok, _} = mnesia:change_config(extra_db_nodes, Nodes -- [node()]),
                case mnesia:change_table_copy_type(schema, node(), disc_copies) of
                    {atomic, ok} -> ok;
                    {aborted, {already_exists, schema, _, disc_copies}} -> ok;
                    SchemaError -> error({schema_copy, SchemaError})
                end,
                [case mnesia:add_table_copy(T, node(), disc_copies) of
                    {atomic, ok} -> ok;
                    {aborted, {already_exists, T, _}} -> ok;
                    CopyError -> error({table_copy, T, CopyError})
                 end || T <- lists:reverse(Names)],
                ok = mnesia:wait_for_tables(Names, 30000),
                check_replicas(Meta, Nodes, false)
        end,
        Joining = [case {T, Majority} of
                       {Meta, true} -> {T, Attrs, joining};
                       _ -> {T, Attrs, Majority}
                   end || {T, Attrs, Majority} <- Tables],
        await_layout(Nodes, Joining, Deadline),
        case {lists:keyfind(Meta, 1, Tables), mnesia:table_info(Meta, majority)} of
            {{Meta, _, true}, false} -> {atomic, ok} = mnesia:change_table_majority(Meta, true);
            _ -> ok
        end,
        ok = symmetric_tables(Nodes, Tables),
        persistent_term:put({Namespace, replicas}, Nodes), ok
    after mnesia:unsubscribe({table, schema, simple}) end.

check_replicas(Meta, Nodes, Create) ->
    case mnesia:sync_transaction(fun() ->
        case mnesia:read(Meta, replicas, write) of
            [] when Create -> mnesia:write({Meta, replicas, Nodes});
            [{Meta, replicas, Nodes}] -> ok;
            _ -> mnesia:abort(replica_set_mismatch)
        end
    end) of
        {atomic, ok} -> ok;
        Error -> error({replicas, Error})
    end.

await_seed(Seed, Meta, Nodes, Deadline) ->
    Group = {?MODULE, Meta, Nodes},
    {Ref, Members} = pg:monitor(py_mnesia_pg, Group),
    try await_seed_member(Seed, Group, Ref, Members, Deadline)
    after pg:demonitor(py_mnesia_pg, Ref) end,
    case erpc:call(Seed, mnesia, dirty_read, [Meta, replicas], 30000) of
        [{Meta, replicas, Nodes}] -> ok;
        _ -> error(replica_set_mismatch)
    end.

await_seed_member(Seed, Group, Ref, Members, Deadline) ->
    case lists:any(fun(P) -> node(P) =:= Seed end, Members) of
        true -> ok;
        false ->
            Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
            receive
                {Ref, join, Group, Joined} ->
                    await_seed_member(Seed, Group, Ref, Joined, Deadline);
                {Ref, leave, Group, _} ->
                    await_seed_member(Seed, Group, Ref, [], Deadline)
            after Timeout -> error({seed_unavailable, Seed}) end
    end.

await_layout(Nodes, Tables, Deadline) ->
    try symmetric_tables(Nodes, Tables)
    catch error:Reason ->
        Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
        receive
            {mnesia_table_event, _} -> await_layout(Nodes, Tables, Deadline)
        after Timeout -> error({replica_layout_timeout, Reason}) end
    end.

symmetric_tables(Nodes, Tables) ->
    [begin
        Layout = {mnesia:table_info(T, disc_copies), mnesia:table_info(T, ram_copies),
                  mnesia:table_info(T, disc_only_copies), mnesia:table_info(T, majority)},
        case Layout of
            {Disc, [], [], Actual} when Actual =:= Majority; Majority =:= joining ->
                case lists:sort(Disc) =:= Nodes of
                    true -> ok;
                    false -> error({replica_set_mismatch, T, Layout})
                end;
            _ -> error({unsupported_replica_layout, T, Layout})
        end
     end || {T, _, Majority} <- Tables], ok.

ensure_started(Dir, CreateSchema) ->
    global:trans({?MODULE, self()}, fun() ->
        case mnesia:system_info(is_running) of
            no ->
                ok = filelib:ensure_dir(filename:join(Dir, "schema.DAT")),
                ok = application:set_env(mnesia, dir, Dir),
                case CreateSchema of
                    true ->
                        case mnesia:create_schema([node()]) of
                            ok -> ok;
                            {error, {_, {already_exists, _}}} -> ok;
                            Other -> error({schema, Other})
                        end;
                    false -> ok
                end,
                ok = application:start(mnesia);
            yes -> ok;
            OtherState -> error({mnesia_state, OtherState})
        end,
        case filename:absname(mnesia:system_info(directory)) of
            Dir -> ok;
            _ -> error(mnesia_directory_mismatch)
        end
    end, [node()]).

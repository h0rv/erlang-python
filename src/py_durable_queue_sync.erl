-module(py_durable_queue_sync).
-behaviour(gen_server).
-export([start_link/0, reply/2, sync/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
reply(From, Result) ->
    try gen_server:call(?MODULE, {enqueue, From, Result}, infinity)
    catch exit:Reason -> gen_server:reply(From, {error, {sync_failed, Reason}}) end.
sync() -> gen_server:call(?MODULE, sync, 30000).
init([]) -> {ok, #{writes => [], syncs => []}}.
handle_call({enqueue, From, Result}, _, #{writes := Waiting} = S) ->
    case Waiting of [] -> erlang:send_after(1, self(), flush); _ -> ok end,
    {reply, ok, S#{writes := [{From, Result} | Waiting]}};
handle_call(sync, From, #{syncs := Waiting} = S) ->
    case Waiting of [] -> erlang:send_after(1, self(), sync_local); _ -> ok end,
    {noreply, S#{syncs := [From | Waiting]}}.
handle_cast(_, State) -> {noreply, State}.
handle_info(sync_local, #{syncs := Waiting} = S) ->
    Sync = try mnesia:sync_log() catch Class:Reason -> {error, {Class, Reason}} end,
    [gen_server:reply(From, Sync) || From <- Waiting],
    {noreply, S#{syncs := []}};
handle_info(flush, #{writes := Waiting} = S) ->
    spawn(fun() -> flush(Waiting) end),
    {noreply, S#{writes := []}}.

flush(Waiting) ->
    Sync = try
        Nodes = mnesia:table_info(dq_item, where_to_write),
        true = lists:member(node(), Nodes),
        Replies = erpc:multicall(Nodes, ?MODULE, sync, [], 30000),
        case lists:all(fun(R) -> R =:= {ok, ok} end, Replies) of
            true -> ok;
            false -> {error, Replies}
        end
    catch Class:Reason -> {error, {Class, Reason}} end,
    [gen_server:reply(From, case Sync of ok -> Result; _ -> {error, {sync_failed, Sync}} end)
     || {From, Result} <- Waiting].

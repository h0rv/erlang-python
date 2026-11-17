-module(py_durable_queue_sync).
-behaviour(gen_server).
-export([start_link/0, reply/2, init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
reply(From, Result) ->
    try gen_server:call(?MODULE, {enqueue, From, Result}, infinity)
    catch exit:Reason -> gen_server:reply(From, {error, {sync_failed, Reason}}) end.
init([]) -> {ok, []}.
handle_call({enqueue, From, Result}, _, Waiting) ->
    case Waiting of [] -> erlang:send_after(1, self(), flush); _ -> ok end,
    {reply, ok, [{From, Result} | Waiting]}.
handle_cast(_, State) -> {noreply, State}.
handle_info(flush, Waiting) ->
    Sync = try mnesia:sync_log() catch Class:Reason -> {error, {Class, Reason}} end,
    [gen_server:reply(From, case Sync of ok -> Result; _ -> {error, {sync_failed, Sync}} end)
     || {From, Result} <- Waiting],
    {noreply, []}.

-module(py_actor_registry).
-behaviour(gen_server).
-export([start_link/0, watch/1, init/1, handle_call/3, handle_cast/2, handle_info/2]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
watch(Group) -> gen_server:call(?MODULE, {watch, Group}).
init([]) ->
    ets:new(py_actor_generations, [named_table, public, set]),
    {ok, #{}}.
handle_call({watch, Group}, _From, State) ->
    Mon = monitor(process, Group),
    {reply, ok, State#{Mon => Group}}.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Mon, process, Group, _}, State) ->
    case maps:take(Mon, State) of
        {Group, Rest} ->
            %% Keyed by group identity, never by a reused logical child ID or
            %% old actor monitor. A late DOWN cannot erase a new generation.
            ets:match_delete(py_actor_generations, {{Group, '_'}, '_', '_', '_', '_'}),
            {noreply, Rest};
        error -> {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.

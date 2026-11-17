%%% @doc Generation registry owned independently of actor groups.
-module(py_actor_registry).
-behaviour(gen_server).
-export([start_link/0, watch/1, own/3, release/1,
         init/1, handle_call/3, handle_cast/2, handle_info/2]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
watch(Group) -> gen_server:call(?MODULE, {watch, Group}).
own(Pid, Gate, Object) -> gen_server:call(?MODULE, {own, Pid, Gate, Object}, infinity).
release(Gate) -> gen_server:call(?MODULE, {release, Gate}, infinity).
init([]) ->
    ets:new(py_actor_generations, [named_table, public, set]),
    {ok, #{monitors => #{}, objects => #{}}}.
handle_call({watch, Group}, _From, #{monitors := Monitors} = State) ->
    Mon = monitor(process, Group),
    {reply, ok, State#{monitors := Monitors#{Mon => {group, Group}}}};
handle_call({own, Pid, Gate, Object}, _From,
            #{monitors := Monitors, objects := Objects} = State) ->
    Mon = monitor(process, Pid),
    {reply, ok, State#{monitors := Monitors#{Mon => {actor, Gate, Object}},
                      objects := Objects#{Gate => []}}};
handle_call({release, Gate}, From, #{objects := Objects} = State) ->
    case maps:find(Gate, Objects) of
        {ok, Waiters} -> {noreply, State#{objects := Objects#{Gate := [From | Waiters]}}};
        error -> {reply, ok, State}
    end.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Mon, process, Pid, _}, #{monitors := Monitors} = State) ->
    case maps:take(Mon, Monitors) of
        {{group, Group}, Rest} ->
            %% Keyed by group identity, never by a reused logical child ID or
            %% old actor monitor. A late DOWN cannot erase a new generation.
            ets:match_delete(py_actor_generations, {{Group, '_'}, '_', '_', '_'}),
            {noreply, State#{monitors := Rest}};
        {{actor, Gate, Object}, Rest} ->
            Registry = self(),
            spawn_link(fun() ->
                case py_nif:actor_gate_wait(Gate) of
                    ok -> ok;
                    {ok, Ref} -> receive {actor_gate_drained, Ref} -> ok end
                end,
                ok = py_worker_pool:drain(Pid),
                ok = py_nif:actor_object_release(Object),
                Registry ! {released, Gate}
            end),
            {noreply, State#{monitors := Rest}};
        error -> {noreply, State}
    end;
handle_info({released, Gate}, #{objects := Objects} = State) ->
    {Waiters, Rest} = maps:take(Gate, Objects),
    [gen_server:reply(From, ok) || From <- Waiters],
    {noreply, State#{objects := Rest}};
handle_info(_, State) -> {noreply, State}.

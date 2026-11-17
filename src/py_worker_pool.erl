%%% @doc Node-wide worker leases with FIFO admission and holder-death barriers.
-module(py_worker_pool).
-behaviour(gen_server).
-export([start_link/0, checkout/1, checkin/1, drain/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
checkout(Preferred) -> gen_server:call(?MODULE, {checkout, Preferred}, infinity).
checkin(Ctx) -> gen_server:call(?MODULE, {checkin, Ctx}, infinity).
drain(Holder) -> gen_server:call(?MODULE, {drain, Holder}, infinity).

init([]) ->
    CPUs = case erlang:system_info(logical_processors_available) of
        N when is_integer(N), N > 0 -> N;
        _ -> erlang:system_info(schedulers_online)
    end,
    Max = application:get_env(erlang_python, worker_pool_max, CPUs * 4),
    true = is_integer(Max) andalso Max > 0,
    Workers = [new_worker() || _ <- lists:seq(1, min(CPUs, Max))],
    {ok, #{free => Workers, busy => #{}, queue => queue:new(),
           workers => Workers, max => Max, drains => #{}}}.

new_worker() ->
    {ok, Ctx} = py_context:new(#{mode => worker, context_owner => self()}),
    monitor(process, Ctx),
    Ctx.

handle_call({checkout, Preferred}, From, #{free := Free, workers := Workers, max := Max} = State) ->
    case Free of
        [] when length(Workers) < Max ->
            Ctx = new_worker(),
            lease(Ctx, From, State#{workers := [Ctx | Workers]});
        [] ->
            Mon = monitor(process, element(1, From)),
            {noreply, State#{queue := queue:in({From, Mon}, maps:get(queue, State))}};
        _ ->
            Ctx = case lists:member(Preferred, Free) of true -> Preferred; false -> hd(Free) end,
            lease(Ctx, From, State#{free := lists:delete(Ctx, Free)})
    end;
handle_call({checkin, Ctx}, {Pid, _}, #{busy := Busy} = State) ->
    case maps:find(Ctx, Busy) of
        {ok, {Pid, Mon}} ->
            demonitor(Mon, [flush]),
            {reply, ok, release(Ctx, Pid, State)};
        _ -> {reply, {error, not_holder}, State}
    end;
handle_call({drain, Pid}, From, #{busy := Busy, drains := Drains} = State) ->
    case lists:any(fun({Holder, _}) -> Holder =:= Pid end, maps:values(Busy)) of
        false -> {reply, ok, State};
        true -> {noreply, State#{drains := Drains#{Pid => [From | maps:get(Pid, Drains, [])]}}}
    end.

lease(Ctx, From, #{busy := Busy} = State) ->
    Pid = element(1, From),
    Mon = monitor(process, Pid),
    gen_server:reply(From, Ctx),
    {noreply, State#{busy := Busy#{Ctx => {Pid, Mon}}}}.

release(Ctx, Pid, #{busy := Busy, drains := Drains, queue := Queue, free := Free} = State) ->
    Remaining = maps:remove(Ctx, Busy),
    NextDrains = case lists:any(fun({Holder, _}) -> Holder =:= Pid end, maps:values(Remaining)) of
        true -> Drains;
        false ->
            [gen_server:reply(From, ok) || From <- maps:get(Pid, Drains, [])],
            maps:remove(Pid, Drains)
    end,
    Next = State#{busy := Remaining, drains := NextDrains},
    case queue:out(Queue) of
        {empty, _} -> Next#{free := [Ctx | Free]};
        {{value, {From, Mon}}, Rest} ->
            demonitor(Mon, [flush]),
            case is_process_alive(element(1, From)) of
                true -> {noreply, Leased} = lease(Ctx, From, Next#{queue := Rest}), Leased;
                false -> release(Ctx, Pid, Next#{queue := Rest})
            end
    end.

handle_info({'DOWN', Mon, process, Pid, _}, #{busy := Busy, workers := Workers} = State) ->
    case lists:member(Pid, Workers) of
        true -> {stop, {worker_died, Pid}, State};
        false ->
            case [{Ctx, Holder} || {Ctx, {Holder, M}} <- maps:to_list(Busy), M =:= Mon] of
                [{Ctx, Pid}] ->
                    Pool = self(),
                    spawn(fun() ->
                        %% This message follows every request sent by the dead holder.
                        _ = py_context:call(Ctx, builtins, id, [0], #{}, infinity),
                        Pool ! {drained, Ctx, Pid}
                    end),
                    {noreply, State};
                [] ->
                    Queue = queue:filter(fun({_, M}) -> M =/= Mon end, maps:get(queue, State)),
                    {noreply, State#{queue := Queue}}
            end
    end;
handle_info({drained, Ctx, Pid}, State) -> {noreply, release(Ctx, Pid, State)};
handle_info(_, State) -> {noreply, State}.
handle_cast(_, State) -> {noreply, State}.
terminate(_, #{workers := Workers}) -> [py_context:destroy(Ctx) || Ctx <- Workers], ok.

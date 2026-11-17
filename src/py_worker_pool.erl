%%% @doc Node-wide worker leases with FIFO admission and holder-death barriers.
-module(py_worker_pool).
-behaviour(gen_server).
-export([start_link/0, checkout/1, checkin/1, drain/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-define(PREFERRED_WAIT_MS, 100).

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

handle_call({checkout, Preferred}, From, #{busy := Busy, queue := Queue} = State) ->
    Mon = monitor(process, element(1, From)),
    {Affinity, Timer} = case maps:is_key(Preferred, Busy) of
        true -> {Preferred, erlang:send_after(?PREFERRED_WAIT_MS, self(), {preferred_timeout, Mon})};
        false -> {undefined, undefined}
    end,
    Entry = {From, Mon, Affinity, Timer},
    Next = State#{queue := queue:in(Entry, Queue)},
    %% A free preferred worker is eligible immediately, without a timer.
    Free = maps:get(free, State),
    case lists:member(Preferred, Free) of
        true -> {noreply, dispatch(Next#{free := [Preferred | lists:delete(Preferred, Free)]})};
        false -> {noreply, dispatch(Next)}
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

release(Ctx, Pid, #{busy := Busy, drains := Drains, free := Free} = State) ->
    Remaining = maps:remove(Ctx, Busy),
    NextDrains = case lists:any(fun({Holder, _}) -> Holder =:= Pid end, maps:values(Remaining)) of
        true -> Drains;
        false ->
            [gen_server:reply(From, ok) || From <- maps:get(Pid, Drains, [])],
            maps:remove(Pid, Drains)
    end,
    dispatch(State#{busy := Remaining, drains := NextDrains, free := [Ctx | Free]}).

dispatch(#{queue := Queue, free := Free, workers := Workers, max := Max} = State) ->
    Eligible = fun({_, _, Preferred, _}) ->
        case Preferred of
            undefined -> Free =/= [] orelse length(Workers) < Max;
            _ -> lists:member(Preferred, Free)
        end
    end,
    {Before, After} = lists:splitwith(fun(Entry) -> not Eligible(Entry) end, queue:to_list(Queue)),
    case After of
        [] -> State;
        [{From, Mon, Preferred, Timer} | Rest] ->
            cancel_timer(Timer),
            demonitor(Mon, [flush]),
            Next = State#{queue := queue:from_list(Before ++ Rest)},
            case is_process_alive(element(1, From)) of
                false -> dispatch(Next);
                true ->
                    {Ctx, Available, All} = case Free of
                        [] -> New = new_worker(), {New, [], [New | Workers]};
                        _ ->
                            Chosen = case Preferred of undefined -> hd(Free); _ -> Preferred end,
                            {Chosen, lists:delete(Chosen, Free), Workers}
                    end,
                    {noreply, Leased} = lease(Ctx, From, Next#{free := Available, workers := All}),
                    dispatch(Leased)
            end
    end.

cancel_timer(undefined) -> ok;
cancel_timer(Timer) -> erlang:cancel_timer(Timer), ok.

handle_info({'DOWN', Mon, process, Pid, _}, #{busy := Busy, workers := Workers} = State) ->
    case lists:member(Pid, Workers) of
        true -> {stop, {worker_died, Pid}, State};
        false ->
            case [{Ctx, Holder} || {Ctx, {Holder, M}} <- maps:to_list(Busy), M =:= Mon] of
                [{Ctx, Pid}] ->
                    Pool = self(),
                    spawn(fun() ->
                        %% This message follows every request sent by the dead holder.
                        MRef = monitor(process, Ctx),
                        Ctx ! {pool_barrier, self(), MRef},
                        receive
                            {MRef, ok} -> demonitor(MRef, [flush]);
                            {'DOWN', MRef, process, Ctx, Reason} -> exit(Reason)
                        end,
                        Pool ! {drained, Ctx, Pid}
                    end),
                    {noreply, State};
                [] ->
                    Queue = queue:filter(fun({_, M, _, Timer}) ->
                        case M =:= Mon of true -> cancel_timer(Timer), false; false -> true end
                    end, maps:get(queue, State)),
                    {noreply, State#{queue := Queue}}
            end
    end;
handle_info({drained, Ctx, Pid}, State) -> {noreply, release(Ctx, Pid, State)};
handle_info({preferred_timeout, Mon}, #{queue := Queue} = State) ->
    Entries = [case Entry of
        {From, Mon, _, Timer} -> cancel_timer(Timer), {From, Mon, undefined, undefined};
        _ -> Entry
    end || Entry <- queue:to_list(Queue)],
    {noreply, dispatch(State#{queue := queue:from_list(Entries)})};
handle_info(_, State) -> {noreply, State}.
handle_cast(_, State) -> {noreply, State}.
terminate(_, #{workers := Workers}) -> [py_context:destroy(Ctx) || Ctx <- Workers], ok.

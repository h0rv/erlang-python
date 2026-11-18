%%% @doc Node-local ownership holders, independent of actor generations.
-module(py_actor_state_owner).
-behaviour(gen_server).
-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).
-record(py_actor_owner, {key, node, pid, token}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ok = net_kernel:monitor_nodes(true),
    self() ! recover,
    {ok, #{opened => false, claims => #{}, cancelled => #{}}}.

handle_call(opened, _, #{opened := Opened} = S) ->
    ok = subscribe(system),
    ok = subscribe({table, py_actor_owner, simple}),
    Result = case Opened of
        true -> ok;
        false -> transaction(fun() ->
            mnesia:foldl(fun(#py_actor_owner{key = K, node = N}, ok) when N =:= node() ->
                                mnesia:delete({py_actor_owner, K}), ok;
                           (_, ok) -> ok end, ok, py_actor_owner)
        end)
    end,
    {reply, Result, S#{opened := Result =:= ok}};
handle_call({claim, _, _}, _, #{opened := false} = S) ->
    {reply, {error, not_open}, S};
handle_call({claim, Key, Ref}, From, #{claims := Claims, cancelled := Cancelled} = S) ->
    case {maps:is_key(Ref, Cancelled), maps:is_key(Ref, Claims)} of
        {true, _} -> {reply, {error, cancelled}, S#{cancelled := maps:remove(Ref, Cancelled)}};
        {_, true} -> {reply, {error, duplicate_ref}, S};
        _ ->
            Manager = self(),
            {Pid, Mon} = spawn_monitor(fun() ->
                M = monitor(process, Manager),
                receive stop -> ok; {'DOWN', M, process, Manager, _} -> ok end
            end),
            Caller = monitor(process, element(1, From)),
            Token = term_to_binary({Key, Pid, make_ref()}),
            Claim = #{key => Key, pid => Pid, token => Token, mon => Mon,
                      caller => Caller, from => From, status => waiting},
            {noreply, wake(S#{claims := Claims#{Ref => Claim}})}
    end;
handle_call({cancel, Ref}, _, #{claims := Claims, cancelled := Cancelled} = S) ->
    case maps:find(Ref, Claims) of
        {ok, Claim} ->
            {Reply, Next} = discard(Ref, Claim, S),
            {reply, Reply, wake(Next)};
        error -> {reply, ok, S#{cancelled := Cancelled#{Ref => true}}}
    end;
handle_call({release, Token}, _, #{claims := Claims} = S) ->
    case [{R, C} || {R, #{token := T} = C} <- maps:to_list(Claims), T =:= Token] of
        [{Ref, Claim}] ->
            {Reply, Next} = discard(Ref, Claim, S),
            {reply, Reply, wake(Next)};
        [] -> {reply, {error, not_owner}, S}
    end.

handle_cast(_, S) -> {noreply, S}.
handle_info(recover, S) ->
    case mnesia:system_info(is_running) =:= yes andalso
         lists:member(py_actor_owner, mnesia:system_info(local_tables)) of
        true ->
            {reply, _, Next} = handle_call(opened, undefined, S),
            {noreply, Next};
        false -> {noreply, S}
    end;
handle_info({'DOWN', Mon, process, _, _}, #{claims := Claims} = S) ->
    Next = lists:foldl(fun({Ref, #{mon := M, caller := C} = Claim}, Acc)
                              when Mon =:= M; Mon =:= C ->
                              {_, Rest} = discard(Ref, Claim, Acc), Rest;
                         (_, Acc) -> Acc end, S, maps:to_list(Claims)),
    {noreply, wake(Next)};
handle_info({mnesia_table_event, _}, S) -> {noreply, wake(S)};
handle_info({mnesia_system_event, _}, S) -> {noreply, wake(S)};
handle_info({nodedown, _}, S) -> {noreply, wake(S)};
handle_info({nodeup, _}, S) -> {noreply, wake(S)};
handle_info(_, S) -> {noreply, S}.

wake(#{claims := Claims} = S) ->
    maps:fold(fun(Ref, Claim, Acc) -> advance(Ref, Claim, Acc) end, S, Claims).

advance(Ref, #{status := releasing} = Claim, S) ->
    {_, Next} = discard(Ref, Claim, S), Next;
advance(_, #{status := owned}, S) -> S;
advance(Ref, #{key := Key, pid := Pid, token := Token, from := From,
               caller := Caller} = Claim, #{claims := Claims} = S) ->
    Result = transaction(fun() ->
        Owners = mnesia:read(py_actor_owner, Key, write),
        case claimable(Owners) of
            true ->
                mnesia:write(#py_actor_owner{key = Key, node = node(), pid = Pid, token = Token}),
                acquired;
            false -> waiting
        end
    end),
    case Result of
        acquired ->
            demonitor(Caller, [flush]),
            gen_server:reply(From, {ok, Token}),
            S#{claims := Claims#{Ref := Claim#{status := owned, caller := undefined}}};
        waiting -> S;
        {error, {no_majority, _}} -> S;
        Error ->
            gen_server:reply(From, Error),
            {_, Next} = discard(Ref, Claim#{status := owned}, S), Next
    end.

claimable([]) -> true;
claimable([#py_actor_owner{node = N, pid = Pid}]) ->
    not lists:member(N, mnesia:system_info(running_db_nodes)) orelse
        (N =:= node() andalso not is_process_alive(Pid)).

discard(Ref, #{key := Key, pid := Pid, token := Token, mon := Mon,
               caller := Caller, status := Status} = Claim, #{claims := Claims} = S) ->
    case Status of waiting -> gen_server:reply(maps:get(from, Claim), {error, cancelled}); _ -> ok end,
    case Caller of undefined -> ok; _ -> demonitor(Caller, [flush]) end,
    Pid ! stop,
    Result = transaction(fun() ->
        case mnesia:read(py_actor_owner, Key, write) of
            [#py_actor_owner{token = Token}] -> mnesia:delete({py_actor_owner, Key});
            _ -> ok
        end
    end),
    case Result of
        ok -> demonitor(Mon, [flush]), {ok, S#{claims := maps:remove(Ref, Claims)}};
        Error -> {Error, S#{claims := Claims#{Ref := Claim#{status := releasing, caller := undefined}}}}
    end.

transaction(Fun) ->
    try mnesia:sync_transaction(Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    catch Class:Reason -> {error, {store_failed, Class, Reason}} end.

subscribe(Event) ->
    case mnesia:subscribe(Event) of
        {ok, _} -> ok;
        {error, {already_exists, _}} -> ok
    end.

-module(py_durable_queue).
-behaviour(gen_server).
-export([start_link/0, register_callbacks/0, open/3, open/4, put/3, claim/3, ack/2, release/2,
         is_open/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-record(dq_item, {id, queue, key, payload, attempt = 0, state = queued, not_before = 0}).
-record(dq_meta, {key, value}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, manager, []).
register_callbacks() ->
    py_callback:register('_queue_open', fun
        ([Dir, Queue, Max]) -> open(Dir, Queue, Max);
        ([Dir, Queue, Max, Replicas]) -> open(Dir, Queue, Max, Replicas)
    end),
    py_callback:register('_queue_put', fun([Queue, Key, Payload]) ->
        put(Queue, case Key of none -> undefined; _ -> Key end, Payload) end),
    py_callback:register('_queue_claim', fun([Queue, Lease, Wait]) ->
        case claim(Queue, Lease, Wait) of
            {ok, Id, Token, Attempt, Payload} -> {ok, Id, {bytes,Token}, Attempt, {bytes,Payload}};
            Other -> Other
        end
    end),
    py_callback:register('_queue_ack', fun([Id, Token]) -> ack(Id, Token) end),
    py_callback:register('_queue_release', fun([Id, Token]) -> release(Id, Token) end), ok.

open(Dir, Queue, Max) -> open(Dir, Queue, Max, []).
open(Dir, Queue, Max, Replicas) when is_binary(Dir), is_binary(Queue), byte_size(Queue) > 0,
                           is_integer(Max), Max > 0, is_list(Replicas) ->
    case lists:all(fun(N) -> is_binary(N) andalso byte_size(N) > 0 end, Replicas) of
        true ->
            Nodes = case Replicas of
                [] -> [node()];
                _ -> lists:usort([binary_to_atom(N, utf8) || N <- Replicas])
            end,
            case lists:member(node(), Nodes) of
                true -> safe_call(?MODULE, {open,
                    filename:absname(unicode:characters_to_list(Dir)), Queue, Max, Nodes});
                false -> {error, local_replica_required}
            end;
        false -> {error, invalid_argument}
    end;
open(_, _, _, _) -> {error, invalid_argument}.
is_open(Queue) ->
    case safe_call(?MODULE, {lookup, Queue}) of {ok, _} -> true; _ -> false end.
put(Queue, Key, Payload) when is_binary(Queue), is_binary(Payload),
                              (is_binary(Key) orelse Key =:= undefined) ->
    case byte_size(Payload) =< 1048576 of
        true -> queue_call(Queue, {put, Key, Payload});
        false -> {error, payload_too_large}
    end;
put(_, _, _) -> {error, invalid_argument}.
claim(Queue, Lease, Wait) when is_binary(Queue), is_integer(Lease), Lease > 0,
                                Lease =< 4294967295, is_integer(Wait), Wait >= 0,
                                Wait =< 4294967295 -> queue_call(Queue, {claim, Lease, Wait});
claim(_, _, _) -> {error, invalid_argument}.
ack(Id, Token) -> item_call(Id, Token, ack).
release(Id, Token) -> item_call(Id, Token, release).
item_call(Id, Token, Op) when is_integer(Id), is_binary(Token) ->
    try
        case mnesia:dirty_read(dq_item, Id) of
            [#dq_item{queue = Queue}] -> queue_call(Queue, {Op, Id, Token});
            [] -> {error, stale_lease}
        end
    catch Class:Reason -> {error, {store_failed, Class, Reason}} end;
item_call(_, _, _) -> {error, invalid_argument}.
queue_call(Queue, Request) ->
    case safe_call(?MODULE, {lookup, Queue}) of
        {ok, Pid} -> safe_call(Pid, Request);
        Error -> Error
    end.
safe_call(Pid, Request) ->
    try gen_server:call(Pid, Request, infinity)
    catch exit:Reason -> {error, {store_failed, Reason}} end.

init(manager) -> process_flag(trap_exit, true), {ok, #{kind => manager, queues => #{}}};
init({queue, Queue, Max}) ->
    {ok, _} = mnesia:subscribe({table, dq_item, simple}),
    {ok, #{kind => queue, name => Queue, max => Max, waiters => [], timer => undefined}}.

handle_call({open, Dir, Queue, Max, Nodes}, From, #{kind := manager, queues := Queues} = S) ->
    Result = try
        ok = ensure_store(Dir, Nodes),
        transaction(fun() ->
            case mnesia:read(dq_meta, {queue, Queue}, write) of
                [] -> mnesia:write(#dq_meta{key = {queue, Queue}, value = {Max, 0}}), ok;
                [#dq_meta{value = {Max, _}}] -> ok;
                _ -> mnesia:abort(queue_options_mismatch)
            end
        end)
    catch Class:Reason -> {error, {store_failed, Class, Reason}} end,
    case Result of
        {ok, ok} ->
            Next = case maps:find(Queue, Queues) of
                {ok, _} -> Queues;
                error ->
                    {ok, Pid} = gen_server:start_link(?MODULE, {queue, Queue, Max}, []),
                    Queues#{Queue => Pid}
            end,
            py_durable_queue_sync:reply(From, ok),
            {noreply, S#{queues := Next}};
        Error -> {reply, Error, S}
    end;
handle_call({lookup, Queue}, _, #{kind := manager, queues := Queues} = S) ->
    Reply = case maps:find(Queue, Queues) of {ok, Pid} -> {ok, Pid}; error -> {error, not_open} end,
    {reply, Reply, S};
handle_call({put, Key, Payload}, From, #{name := Queue} = S) ->
    Result = transaction(fun() ->
        case Key =/= undefined andalso mnesia:read(dq_meta, {dedup, Queue, Key}) =/= [] of
            true -> {ok, duplicate};
            false ->
                [#dq_meta{value = {Max, Count}}] = mnesia:read(dq_meta, {queue, Queue}, write),
                case Count < Max of false -> mnesia:abort(full); true -> ok end,
                Id = case mnesia:read(dq_meta, sequence, write) of
                    [] -> 1; [#dq_meta{value = Last}] -> Last + 1
                end,
                mnesia:write(#dq_meta{key = sequence, value = Id}),
                mnesia:write(#dq_meta{key = {queue, Queue}, value = {Max, Count+1}}),
                case Key of undefined -> ok;
                    _ -> mnesia:write(#dq_meta{key = {dedup, Queue, Key}, value = Id}) end,
                mnesia:write(#dq_item{id = Id, queue = Queue, key = Key, payload = Payload}), {ok, stored}
        end
    end),
    reply_write(From, Result), {noreply, wake(S)};
handle_call({claim, Lease, Wait}, From, S) ->
    S1 = wake(S),
    case take(maps:get(name, S), Lease) of
        {ok, empty} when Wait > 0 ->
            Mon = monitor(process, element(1, From)),
            W = {From, Lease, erlang:monotonic_time(millisecond)+Wait, Mon},
            {noreply, arm(S1#{waiters := maps:get(waiters, S1) ++ [W]})};
        {ok, empty} -> {reply, empty, S1};
        Result -> reply_write(From, Result), {noreply, arm(S1)}
    end;
handle_call({Op, Id, Token}, From, S) when Op =:= ack; Op =:= release ->
    Result = transaction(fun() ->
        Now = erlang:system_time(millisecond),
        case mnesia:read(dq_item, Id, write) of
            [#dq_item{state = {leased, Token, Until}} = J] when Until > Now ->
                case Op of
                    release -> mnesia:write(J#dq_item{state = queued});
                    ack ->
                        mnesia:delete({dq_item, Id}),
                        #dq_item{queue = Q, key = K} = J,
                        [#dq_meta{value = {Max, C}}] = mnesia:read(dq_meta, {queue, Q}, write),
                        mnesia:write(#dq_meta{key = {queue, Q}, value = {Max, C-1}}),
                        case K of undefined -> ok; _ -> mnesia:delete({dq_meta, {dedup, Q, K}}) end
                end, ok;
            _ -> mnesia:abort(stale_lease)
        end
    end),
    reply_write(From, Result), {noreply, wake(S)}.

reply_write(From, {ok, Result}) -> py_durable_queue_sync:reply(From, Result);
reply_write(From, Error) -> gen_server:reply(From, Error).
handle_cast(_, S) -> {noreply, S}.
handle_info(wake, S) -> {noreply, wake(S)};
handle_info({mnesia_table_event, _}, #{kind := queue} = S) -> {noreply, wake(S)};
handle_info({'DOWN', Mon, process, _, _}, #{waiters := Ws} = S) ->
    {noreply, arm(S#{waiters := [W || W = {_, _, _, M} <- Ws, M =/= Mon]})};
handle_info({'EXIT', Pid, _}, #{kind := manager, queues := Qs} = S) ->
    {noreply, S#{queues := maps:filter(fun(_, P) -> P =/= Pid end, Qs)}};
handle_info(_, S) -> {noreply, S}.
terminate(_, #{kind := manager, queues := Qs}) ->
    [exit(P, shutdown) || P <- maps:values(Qs)], ok;
terminate(_, _) -> ok.

take(Queue, Lease) ->
    Token = crypto:strong_rand_bytes(24),
    transaction(fun() ->
        Now = erlang:system_time(millisecond),
        Candidate = mnesia:foldl(fun(J, Acc) ->
            Eligible = J#dq_item.queue =:= Queue andalso J#dq_item.not_before =< Now andalso
                case J#dq_item.state of queued -> true; {leased, _, Until} -> Until =< Now end,
            case Eligible andalso (Acc =:= none orelse J#dq_item.id < Acc#dq_item.id) of
                true -> J; false -> Acc
            end
        end, none, dq_item),
        case Candidate of
            none -> empty;
            #dq_item{id = Id, attempt = A, payload = Payload} = J ->
                mnesia:write(J#dq_item{state = {leased, Token, Now+Lease}, attempt = A+1}),
                {ok, Id, Token, A+1, Payload}
        end
    end).

wake(#{waiters := Ws} = S) ->
    Now = erlang:monotonic_time(millisecond),
    {Expired, Live} = lists:partition(fun({_,_,D,_}) -> D =< Now end, Ws),
    [begin demonitor(M,[flush]), gen_server:reply(F,empty) end || {F,_,_,M} <- Expired],
    drain(S#{waiters := Live}).
drain(#{waiters := []} = S) -> arm(S);
drain(#{waiters := [{From, Lease, Deadline, Mon} | Tail], name := Queue} = S) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            demonitor(Mon, [flush]), gen_server:reply(From, empty), drain(S#{waiters := Tail});
        false ->
            case take(Queue, Lease) of
                {ok, empty} -> arm(S);
                Result ->
                    demonitor(Mon, [flush]), reply_write(From, Result), drain(S#{waiters := Tail})
            end
    end.
arm(#{timer := Timer, waiters := Ws, name := Queue} = S) ->
    case Timer of undefined -> ok; _ -> erlang:cancel_timer(Timer) end,
    Next = case Ws of
        [] -> undefined;
        _ ->
            Now = erlang:system_time(millisecond),
            Remaining = [max(1,D-erlang:monotonic_time(millisecond)) || {_,_,D,_} <- Ws],
            Expiry = try mnesia:activity(sync_dirty, fun() ->
                mnesia:foldl(fun(#dq_item{queue = Q, state = State, not_before = NB}, Acc) when Q =:= Queue ->
                    Until = case State of queued -> NB; {leased,_,U} -> max(U,NB) end,
                    case Until > Now of true -> [Until-Now | Acc]; false -> Acc end;
                    (_, Acc) -> Acc end, [], dq_item)
            end) catch Class:Reason -> {error, {store_failed, Class, Reason}} end,
            case Expiry of
                {error, _} = Error ->
                    [begin demonitor(M,[flush]), gen_server:reply(F,Error) end || {F,_,_,M} <- Ws],
                    undefined;
                _ -> erlang:send_after(lists:min(Remaining ++ Expiry), self(), wake)
            end
    end,
    S#{timer := Next, waiters := case Next of undefined -> []; _ -> Ws end}.

transaction(Fun) ->
    try
        ok = symmetric_tables(persistent_term:get({?MODULE, replicas})),
        case mnesia:sync_transaction(Fun) of
            {atomic, R} -> {ok, R};
            {aborted, R} -> {error, R}
        end
    catch Class:Reason -> {error, {store_failed, Class, Reason}} end.

ensure_store(Dir, Nodes) ->
    py_mnesia:ensure_store(Dir, Nodes, tables(), dq_meta, ?MODULE, self()).

tables() ->
    [{dq_item, record_info(fields, dq_item), false},
     {dq_meta, record_info(fields, dq_meta), false}].

symmetric_tables(Nodes) -> py_mnesia:symmetric_tables(Nodes, tables()).

%%% @doc Supervised data actor generations and native admission settlement.
-module(py_actor_group).
-behaviour(gen_server).
-export([start_link/1, register_callbacks/0,
         start_data_link/5, init/1, handle_call/3, handle_cast/2,
         handle_info/2, handle_continue/2, terminate/2]).

start_link(Max) -> gen_server:start_link(?MODULE, Max, []).

register_callbacks() ->
    py_callback:register('_actor_group_open', fun([Max]) when is_integer(Max), Max > 0 ->
        Id = make_ref(),
        Spec = #{id => Id, start => {?MODULE, start_link, [Max]},
                 restart => temporary, shutdown => infinity},
        supervisor:start_child(py_actor_root, Spec)
    end),
    py_callback:register('_actor_group_spawn', fun([Group, Id, Factory, Count, Bytes, Restart])
      when is_pid(Group), node(Group) =:= node() ->
        gen_server:call(Group, {spawn, Id, Factory, Count, Bytes, Restart}, infinity)
    end),
    py_callback:register('_actor_group_stop', fun([Group, Id]) when is_pid(Group), node(Group) =:= node() ->
        gen_server:call(Group, {stop, Id}, infinity)
    end),
    py_callback:register('_actor_group_resolve', fun([Group, Id]) when is_pid(Group), node(Group) =:= node() ->
        gen_server:call(Group, {resolve, Id}, infinity)
    end),
    py_callback:register('_actor_group_info', fun([Group, Id, Generation])
      when is_pid(Group), node(Group) =:= node(), is_integer(Generation) ->
        gen_server:call(Group, {info, Id, Generation}, infinity)
    end),
    py_callback:register('_actor_group_crash', fun([Group, Id, Generation])
      when is_pid(Group), node(Group) =:= node(), is_integer(Generation) ->
        gen_server:call(Group, {crash, Id, Generation}, infinity)
    end),
    py_callback:register('_actor_context_counts', fun([]) ->
        #{ctx_created := Created, ctx_destroyed := Destroyed} = py_nif:get_debug_counters(),
        {ok, {Created, Destroyed}}
    end),
    py_callback:register('_actor_group_close', fun([Group]) when is_pid(Group), node(Group) =:= node() ->
        try gen_server:stop(Group, normal, infinity) catch exit:{noproc, _} -> ok end
    end),
    py_callback:register('_actor_data_call', fun([Pid, Gate, Ticket, Payload])
      when is_pid(Pid), node(Pid) =:= node(), is_binary(Payload) ->
        case py_nif:actor_ticket_commit(Ticket, Gate, byte_size(Payload)) of
            ok ->
                try gen_server:call(Pid, {data, Gate, Ticket, Payload}, infinity)
                catch exit:Reason -> settle_abandoned(Pid, Gate, Ticket), exit(Reason)
                end;
            Error -> py_nif:actor_ticket_reject(Ticket), Error
        end
    end),
    ok.

init(Max) when is_integer(Max), Max > 0 ->
    process_flag(trap_exit, true),
    ok = py_actor_registry:watch(self()),
    {ok, Sup} = py_supervision:start_link(#{strategy => one_for_one,
        intensity => 5, period => 10, mailbox => bounded, max_children => Max}),
    {ok, #{sup => Sup, max => Max, ids => [], temporary => #{},
           diagnostic => none, deferred => queue:new()}}.

handle_call({resolve, _} = Request, From, State) ->
    handle_request(Request, From, State);
handle_call({info, _, _} = Request, From, State) ->
    handle_request(Request, From, State);
handle_call(Request, From, #{diagnostic := {_, _, _}} = State) ->
    defer({call, Request, From}, State);
handle_call(Request, From, State) ->
    handle_request(Request, From, reap_finished(State)).

handle_request({spawn, Id, Factory, Count, Bytes, Restart}, _From,
            #{sup := Sup, max := Max, ids := Ids} = State)
  when is_binary(Id), is_integer(Count), Count > 0, is_integer(Bytes), Bytes > 0,
       (Restart =:= <<"permanent">> orelse Restart =:= <<"transient">> orelse Restart =:= <<"temporary">>) ->
    case {lists:member(Id, Ids), length(Ids) < Max} of
        {true, _} -> {reply, {error, duplicate_child}, State};
        {_, false} -> {reply, {error, max_children}, State};
        {false, true} ->
            Policy = case Restart of <<"permanent">> -> permanent;
                <<"transient">> -> transient; <<"temporary">> -> temporary end,
            Spec = #{id => Id, start => {?MODULE, start_data_link,
                         [self(), Id, Factory, Count, Bytes]},
                     restart => Policy, shutdown => infinity},
            case supervisor:start_child(Sup, Spec) of
                {ok, Pid} ->
                    Next = track_temporary(Id, Pid, Policy, State#{ids := [Id | Ids]}),
                    {reply, resolve(self(), Id), Next};
                Error -> {reply, Error, State}
            end
    end;
handle_request({stop, Id}, _From, #{sup := Sup} = State) ->
    case supervisor:terminate_child(Sup, Id) of
        ok ->
            %% OTP removes temporary specs itself, including explicit stops.
            case supervisor:delete_child(Sup, Id) of
                ok -> ok;
                {error, not_found} -> ok
            end,
            finish_stop(Id, State);
        {error, not_found} -> finish_stop(Id, State);
        Error -> {reply, Error, State}
    end;
handle_request({resolve, Id}, _From, State) ->
    {reply, resolve(self(), Id), State};
handle_request({info, Id, Generation}, _From, State) ->
    Reply = case guarded(Id, Generation) of
        {ok, {Pid, Gate}} ->
            #{count := Count, bytes := Bytes} = py_nif:actor_gate_info(Gate),
            {ok, {{bytes, list_to_binary(pid_to_list(Pid))}, Generation, Count, Bytes}};
        Error -> Error
    end,
    {reply, Reply, State};
handle_request({crash, Id, Generation}, From, #{temporary := Temporary} = State) ->
    case guarded(Id, Generation) of
        {ok, {Pid, Gate}} ->
            Group = self(),
            IsTemporary = maps:is_key(Id, Temporary),
            Worker = spawn_link(fun() ->
                Mon = monitor(process, Pid),
                exit(Pid, kill),
                receive {'DOWN', Mon, process, Pid, _} -> ok end,
                wait_completion(Gate),
                Reply = case IsTemporary of
                    true -> {ok, killed};
                    false -> await_replacement(Group, Id, Generation,
                        erlang:monotonic_time(millisecond) + 5000)
                end,
                Group ! {diagnostic_done, self(), Reply}
            end),
            {noreply, State#{diagnostic := {Worker, Id, From}}};
        Error -> {reply, Error, State}
    end;
handle_request(_, _From, State) -> {reply, {error, invalid_request}, State}.

track_temporary(Id, Pid, temporary, #{temporary := Temporary} = State) ->
    [{_, Pid, Generation, _}] = ets:lookup(py_actor_generations, {self(), Id}),
    monitor(process, Pid, [{tag, {temporary, Id, Generation}}]),
    State#{temporary := Temporary#{Id => Generation}};
track_temporary(_Id, _Pid, _Policy, State) -> State.

finish_stop(Id, State) ->
    case ets:lookup(py_actor_generations, {self(), Id}) of
        [Snapshot = {_, _, _, Gate}] ->
            wait_completion(Gate),
            ets:delete_object(py_actor_generations, Snapshot);
        [] -> ok
    end,
    {reply, {ok, stopped}, forget_child(Id, State)}.

forget_child(Id, #{ids := Ids, temporary := Temporary} = State) ->
    State#{ids := lists:delete(Id, Ids), temporary := maps:remove(Id, Temporary)}.

%% A missing OTP spec alone is not a free slot: its Python
%% effect may still be draining. Check both before quota or duplicate-ID
%% admission. Permanent/transient specs retain their existing OTP lifecycle.
reap_finished(#{temporary := Temporary} = State) ->
    maps:fold(fun reap_finished/3, State, Temporary).

reap_finished(Id, Generation, #{sup := Sup} = State) ->
    case ets:lookup(py_actor_generations, {self(), Id}) of
        [Snapshot = {_, Pid, Generation, Gate}] ->
            case not is_process_alive(Pid) of
                true ->
                    case py_nif:actor_gate_info(Gate) of
                        #{unsettled := 0} ->
                            case lists:keymember(Id, 1, supervisor:which_children(Sup)) of
                                false ->
                                    ok = py_actor_registry:release(Gate),
                                    ets:delete_object(py_actor_generations, Snapshot),
                                    forget_child(Id, State);
                                true -> State
                            end;
                        _ -> State
                    end;
                false -> State
            end;
        _ -> State
    end.

reap_later(Id, Generation, #{temporary := Temporary} = State) ->
    case maps:find(Id, Temporary) of
        {ok, Generation} ->
            Next = reap_finished(Id, Generation, State),
            case maps:find(Id, maps:get(temporary, Next)) of
                {ok, Generation} ->
                    Group = self(),
                    [{_, _, _, Gate}] = ets:lookup(py_actor_generations, {Group, Id}),
                    spawn(fun() ->
                        wait_completion(Gate),
                        Group ! {reap_temporary, Id, Generation}
                    end);
                _ -> ok
            end,
            {noreply, Next};
        _ -> {noreply, State}
    end.

await_replacement(Group, Id, Old, Deadline) ->
    case resolve(Group, Id) of
        {ok, {_, New, _}} when New =/= Old -> {ok, killed};
        _ ->
            Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
            receive
                {actor_started, Id} -> await_replacement(Group, Id, Old, Deadline)
            after Timeout -> {error, restart_timeout}
            end
    end.

guarded(Id, Generation) ->
    case ets:lookup(py_actor_generations, {self(), Id}) of
        [{_, Pid, Generation, Gate}] ->
            case is_process_alive(Pid) of
                true -> {ok, {Pid, Gate}};
                false -> {error, restarting}
            end;
        [{_, _, Current, _}] -> {error, {generation_changed, Generation, Current}};
        [] -> {error, unknown_child}
    end.

resolve(Group, Id) ->
    case ets:lookup(py_actor_generations, {Group, Id}) of
        [{_, Pid, Generation, Gate}] ->
            case is_process_alive(Pid) of
                true -> {ok, {Pid, Generation, Gate}};
                false -> {error, restarting}
            end;
        [] -> {error, unknown_child}
    end.

%% Called by the real OTP supervisor for every generation. The previous
%% gate's native completion is the safe restart boundary.
start_data_link(Group, Id, Factory, Count, Bytes) ->
    case ets:lookup(py_actor_generations, {Group, Id}) of
        [{_, _, _, OldGate}] ->
            wait_completion(OldGate);
        [] -> ok
    end,
    Result = py_data_actor:start_link(Group, Id, Factory, Count, Bytes),
    Group ! {actor_started, Id},
    Result.

wait_completion(Gate) ->
    case py_nif:actor_gate_wait(Gate) of
        ok -> ok;
        {ok, Ref} -> receive {actor_gate_drained, Ref} -> ok end
    end,
    py_actor_registry:release(Gate).

%% A committed call whose actor died before Python ran it has no completion.
%% The lease barrier proves that no request from the dead holder can run later.
settle_abandoned(Pid, _Gate, Ticket) ->
    case is_process_alive(Pid) of
        true -> ok;
        false ->
            _ = spawn(fun() ->
                ok = py_worker_pool:drain(Pid),
                case py_nif:actor_ticket_info(Ticket) of
                    committed -> ok = py_nif:task_ticket_complete(Ticket);
                    _ -> ok
                end
            end),
            ok
    end.

handle_cast(_, State) -> {noreply, State}.
handle_info({'EXIT', Sup, Reason}, #{sup := Sup} = State) -> {stop, Reason, State};
handle_info({actor_started, Id} = Started, #{diagnostic := {Worker, Id, _}} = State) ->
    Worker ! Started,
    {noreply, State};
handle_info({diagnostic_done, Worker, Reply}, #{diagnostic := {Worker, _, From}} = State) ->
    finish_diagnostic(From, Reply, State);
handle_info({'EXIT', Worker, Reason}, #{diagnostic := {Worker, _, From}} = State) ->
    finish_diagnostic(From, {error, {diagnostic_failed, Reason}}, State);
handle_info({{temporary, Id, Generation}, _Mon, process, _Pid, _Reason}, State) ->
    handle_info({reap_temporary, Id, Generation}, State);
handle_info({reap_temporary, Id, Generation}, #{diagnostic := {_, _, _}} = State) ->
    defer({reap, Id, Generation}, State);
handle_info({reap_temporary, Id, Generation}, State) ->
    reap_later(Id, Generation, State);
handle_info(_, State) -> {noreply, State}.

%% The supervisor may itself be starting a replacement. Keep lifecycle
%% changes ordered without calling it from the group during the diagnostic.
defer(Request, #{deferred := Deferred} = State) ->
    {noreply, State#{deferred := queue:in(Request, Deferred)}}.

finish_diagnostic(From, Reply, State) ->
    gen_server:reply(From, Reply),
    {noreply, State#{diagnostic := none}, {continue, deferred}}.

handle_continue(deferred, #{deferred := Deferred} = State) ->
    case queue:out(Deferred) of
        {{value, Request}, Rest} ->
            Next = State#{deferred := Rest},
            Result = case Request of
                {call, Call, From} ->
                    case handle_call(Call, From, Next) of
                        {reply, Reply, Updated} ->
                            gen_server:reply(From, Reply),
                            {noreply, Updated};
                        Pending -> Pending
                    end;
                {reap, Id, Generation} -> reap_later(Id, Generation, Next)
            end,
            case Result of
                {noreply, #{diagnostic := none} = UpdatedState} ->
                    {noreply, UpdatedState, {continue, deferred}};
                _ -> Result
            end;
        {empty, _} -> {noreply, State}
    end.

terminate(_, #{sup := Sup, ids := Ids, diagnostic := Diagnostic}) ->
    case Diagnostic of
        {Worker, _, _} -> exit(Worker, shutdown);
        none -> ok
    end,
    unlink(Sup),
    case is_process_alive(Sup) of true -> gen_server:stop(Sup, shutdown, infinity); false -> ok end,
    lists:foreach(fun(Id) ->
        case ets:lookup(py_actor_generations, {self(), Id}) of
            [{_, _, _, Gate}] -> wait_completion(Gate);
            [] -> ok
        end,
        ets:delete(py_actor_generations, {self(), Id})
    end, Ids).

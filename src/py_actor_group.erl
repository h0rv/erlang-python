-module(py_actor_group).
-behaviour(gen_server).
-export([start_link/1, register_callbacks/0,
         start_data_link/5, init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2]).

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
    {ok, #{sup => Sup, max => Max, ids => [], temporary => #{}}}.

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
        {ok, {Pid, Gate, _Ctx}} ->
            #{count := Count, bytes := Bytes} = py_nif:actor_gate_info(Gate),
            {ok, {{bytes, list_to_binary(pid_to_list(Pid))}, Generation, Count, Bytes}};
        Error -> Error
    end,
    {reply, Reply, State};
handle_request({crash, Id, Generation}, _From, #{temporary := Temporary} = State) ->
    Reply = case guarded(Id, Generation) of
        {ok, {Pid, Gate, Ctx}} ->
            Mon = monitor(process, Pid),
            exit(Pid, kill),
            receive {'DOWN', Mon, process, Pid, _} -> ok end,
            wait_context(Ctx),
            wait_completion(Gate),
            case maps:is_key(Id, Temporary) of
                true -> {ok, killed};
                false -> await_replacement(Id, Generation, erlang:monotonic_time(millisecond) + 5000)
            end;
        Error -> Error
    end,
    {reply, Reply, State};
handle_request(_, _From, State) -> {reply, {error, invalid_request}, State}.

track_temporary(Id, Pid, temporary, #{temporary := Temporary} = State) ->
    [{_, Pid, Generation, _, _, _}] = ets:lookup(py_actor_generations, {self(), Id}),
    monitor(process, Pid, [{tag, {temporary, Id, Generation}}]),
    State#{temporary := Temporary#{Id => Generation}};
track_temporary(_Id, _Pid, _Policy, State) -> State.

finish_stop(Id, State) ->
    case ets:lookup(py_actor_generations, {self(), Id}) of
        [Snapshot = {_, _, _, Gate, Ctx, _}] ->
            wait_context(Ctx), wait_completion(Gate),
            ets:delete_object(py_actor_generations, Snapshot);
        [] -> ok
    end,
    {reply, {ok, stopped}, forget_child(Id, State)}.

forget_child(Id, #{ids := Ids, temporary := Temporary} = State) ->
    State#{ids := lists:delete(Id, Ids), temporary := maps:remove(Id, Temporary)}.

%% A missing OTP spec alone is not a free slot: its owned context or Python
%% effect may still be draining. Check all three before quota or duplicate-ID
%% admission. Permanent/transient specs retain their existing OTP lifecycle.
reap_finished(#{temporary := Temporary} = State) ->
    maps:fold(fun reap_finished/3, State, Temporary).

reap_finished(Id, Generation, #{sup := Sup} = State) ->
    case ets:lookup(py_actor_generations, {self(), Id}) of
        [Snapshot = {_, Pid, Generation, Gate, Ctx, _}] ->
            case not is_process_alive(Pid) andalso not is_process_alive(Ctx) of
                true ->
                    case py_nif:actor_gate_info(Gate) of
                        #{unsettled := 0} ->
                            case lists:keymember(Id, 1, supervisor:which_children(Sup)) of
                                false ->
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
                    erlang:send_after(10, self(), {reap_temporary, Id, Generation});
                _ -> ok
            end,
            {noreply, Next};
        _ -> {noreply, State}
    end.

await_replacement(Id, Old, Deadline) ->
    case resolve(self(), Id) of
        {ok, {_, New, _}} when New =/= Old -> {ok, killed};
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> receive after 1 -> await_replacement(Id, Old, Deadline) end;
                false -> {error, restart_timeout}
            end
    end.

guarded(Id, Generation) ->
    case ets:lookup(py_actor_generations, {self(), Id}) of
        [{_, Pid, Generation, Gate, Ctx, _}] ->
            case is_process_alive(Pid) of
                true -> {ok, {Pid, Gate, Ctx}};
                false -> {error, restarting}
            end;
        [{_, _, Current, _, _, _}] -> {error, {generation_changed, Generation, Current}};
        [] -> {error, unknown_child}
    end.

resolve(Group, Id) ->
    case ets:lookup(py_actor_generations, {Group, Id}) of
        [{_, Pid, Generation, Gate, _Ctx, _}] ->
            case is_process_alive(Pid) of
                true -> {ok, {Pid, Generation, Gate}};
                false -> {error, restarting}
            end;
        [] -> {error, unknown_child}
    end.

%% Called by the real OTP supervisor for every generation. The previous
%% context's DOWN plus native completion is the safe restart boundary.
start_data_link(Group, Id, Factory, Count, Bytes) ->
    case ets:lookup(py_actor_generations, {Group, Id}) of
        [{_, _, _, OldGate, OldCtx, _}] ->
            wait_context(OldCtx), wait_completion(OldGate);
        [] -> ok
    end,
    py_data_actor:start_link(Group, Id, Factory, Count, Bytes).

%% A killed context PID is not proof that its native worker stopped. The
%% existing gate owns those completions independently of either Erlang PID.
wait_completion(Gate) ->
    case py_nif:actor_gate_info(Gate) of
        #{unsettled := 0} -> ok;
        _ -> receive after 10 -> wait_completion(Gate) end
    end.

wait_context(Ctx) ->
    Mon = monitor(process, Ctx),
    receive {'DOWN', Mon, process, Ctx, _} -> ok end.

%% A committed call whose actor died before Python ran it has no completion.
%% Its context finishes any in-flight request before honoring owner death, so
%% clean native shutdown proves no body can still run and settle the ticket.
%% The generation row outlives this gate's unsettled tickets.
settle_abandoned(Pid, Gate, Ticket) ->
    case is_process_alive(Pid) of
        true -> ok;
        false ->
            case ets:match_object(py_actor_generations, {'_', Pid, '_', Gate, '_', '_'}) of
                [{_, _, _, _, Ctx, Native}] ->
                    _ = spawn(fun() ->
                        wait_context(Ctx),
                        case py_nif:context_cleanup_status(Native) of
                            clean -> ok = py_nif:task_ticket_reap(Ticket, Native);
                            _ -> ok
                        end
                    end),
                    ok;
                [] -> ok
            end
    end.

handle_cast(_, State) -> {noreply, State}.
handle_info({'EXIT', Sup, Reason}, #{sup := Sup} = State) -> {stop, Reason, State};
handle_info({{temporary, Id, Generation}, _Mon, process, _Pid, _Reason}, State) ->
    reap_later(Id, Generation, State);
handle_info({reap_temporary, Id, Generation}, State) ->
    reap_later(Id, Generation, State);
handle_info(_, State) -> {noreply, State}.
terminate(_, #{sup := Sup, ids := Ids}) ->
    unlink(Sup),
    case is_process_alive(Sup) of true -> gen_server:stop(Sup, shutdown, infinity); false -> ok end,
    lists:foreach(fun(Id) ->
        case ets:lookup(py_actor_generations, {self(), Id}) of
            [{_, _, _, Gate, Ctx, _}] -> wait_context(Ctx), wait_completion(Gate);
            [] -> ok
        end,
        ets:delete(py_actor_generations, {self(), Id})
    end, Ids).

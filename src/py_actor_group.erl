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
    py_callback:register('_actor_group_close', fun([Group]) when is_pid(Group), node(Group) =:= node() ->
        try gen_server:stop(Group, normal, infinity) catch exit:{noproc, _} -> ok end
    end),
    py_callback:register('_actor_data_call', fun([Pid, Gate, Ticket, Payload])
      when is_pid(Pid), node(Pid) =:= node(), is_binary(Payload) ->
        case py_nif:actor_ticket_commit(Ticket, Gate, byte_size(Payload)) of
            ok -> gen_server:call(Pid, {data, Gate, Ticket, Payload}, infinity);
            Error -> py_nif:actor_ticket_reject(Ticket), Error
        end
    end),
    ok.

init(Max) when is_integer(Max), Max > 0 ->
    process_flag(trap_exit, true),
    ok = py_actor_registry:watch(self()),
    {ok, Sup} = py_supervision:start_link(#{strategy => one_for_one,
        intensity => 5, period => 10, mailbox => bounded, max_children => Max}),
    {ok, #{sup => Sup, max => Max, ids => []}}.

handle_call({spawn, Id, Factory, Count, Bytes, Restart}, _From,
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
                {ok, _Pid} -> {reply, resolve(self(), Id), State#{ids := [Id | Ids]}};
                Error -> {reply, Error, State}
            end
    end;
handle_call({stop, Id}, _From, #{sup := Sup, ids := Ids} = State) ->
    case supervisor:terminate_child(Sup, Id) of
        ok ->
            ok = supervisor:delete_child(Sup, Id),
            case ets:lookup(py_actor_generations, {self(), Id}) of
                [{_, _, _, Gate, Ctx}] -> wait_context(Ctx), wait_completion(Gate);
                [] -> ok
            end,
            ets:delete(py_actor_generations, {self(), Id}),
            {reply, {ok, stopped}, State#{ids := lists:delete(Id, Ids)}};
        Error -> {reply, Error, State}
    end;
handle_call({resolve, Id}, _From, State) ->
    {reply, resolve(self(), Id), State};
handle_call(_, _From, State) -> {reply, {error, invalid_request}, State}.

resolve(Group, Id) ->
    case ets:lookup(py_actor_generations, {Group, Id}) of
        [{_, Pid, Generation, Gate, _Ctx}] ->
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
        [{_, _, _, OldGate, OldCtx}] ->
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

handle_cast(_, State) -> {noreply, State}.
handle_info({'EXIT', Sup, Reason}, #{sup := Sup} = State) -> {stop, Reason, State};
handle_info(_, State) -> {noreply, State}.
terminate(_, #{sup := Sup, ids := Ids}) ->
    unlink(Sup),
    case is_process_alive(Sup) of true -> gen_server:stop(Sup, shutdown, infinity); false -> ok end,
    lists:foreach(fun(Id) ->
        case ets:lookup(py_actor_generations, {self(), Id}) of
            [{_, _, _, Gate, Ctx}] -> wait_context(Ctx), wait_completion(Gate);
            [] -> ok
        end,
        ets:delete(py_actor_generations, {self(), Id})
    end, Ids).

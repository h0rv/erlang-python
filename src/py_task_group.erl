-module(py_task_group).
-behaviour(gen_server).
-export([start_link/2, register_callbacks/0, init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2]).

start_link(Count, Bytes) -> gen_server:start_link(?MODULE, {Count, Bytes}, []).
register_callbacks() ->
    py_callback:register('_task_open', fun([Count, Bytes]) ->
        Spec = #{id => make_ref(), start => {?MODULE, start_link, [Count, Bytes]},
                 restart => temporary, shutdown => infinity},
        case supervisor:start_child(py_actor_root, Spec) of
            {ok, Pid} -> gen_server:call(Pid, gate);
            Error -> Error
        end
    end),
    py_callback:register('_task_start', fun([Group, Gate, Ticket, Payload, Factory]) ->
        safe_call(Group, {start, Gate, Ticket, Payload, Factory});
        ([Group, Gate, Ticket, Payload, Mode, Entry]) ->
        safe_call(Group, {start_named, task_mode(Mode), Gate, Ticket, Payload, Entry})
    end),
    py_callback:register('_task_wait', fun([Group, Pid]) ->
        safe_call(Group, {wait, Pid})
    end),
    py_callback:register('_task_cancel', fun([Group, Pid]) -> safe_call(Group, {cancel, Pid}) end),
    py_callback:register('_task_snapshot', fun([Group, Pid]) ->
        case safe_call(Group, {isolated_context, Pid}) of
            {ok, Ctx} -> py_context:thread_snapshot(Ctx);
            Error -> Error
        end
    end),
    py_callback:register('_task_terminate', fun([Group, Pid]) ->
        case safe_call(Group, {isolated_context, Pid}) of
            {ok, Ctx} ->
                %% The normal task exit protocol, not this RPC, acknowledges
                %% OS child exit, ticket settlement and ownership release.
                spawn(fun() -> py_context:kill(Ctx) end),
                ok;
            {error, task_finished} -> ok;
            {error, unknown_task} -> ok;
            Error -> Error
        end
    end),
    py_callback:register('_task_shutdown', fun([Group, Budget]) -> safe_call(Group, {shutdown, Budget}) end),
    py_callback:register('_task_info', fun([Group]) -> safe_call(Group, info) end),
    py_callback:register('_task_dispose', fun([Group]) ->
        try
            case gen_server:call(Group, disposal) of
                {ok, Native} ->
                    gen_server:stop(Group, normal, infinity),
                    case py_nif:context_cleanup_status(Native) of
                        clean -> ok;
                        Status -> {error, {uncertain_inflight, {control_cleanup, Status}}}
                    end;
                Error -> Error
            end
        catch exit:Reason -> {error, {uncertain_inflight, Reason}} end
    end),
    ok.

safe_call(Group, Request) ->
    try gen_server:call(Group, Request, infinity)
    catch exit:Reason -> {error, {uncertain_inflight, Reason}} end.

task_mode(<<"owngil">>) -> owngil;
task_mode(<<"isolated">>) -> isolated;
task_mode(<<"worker">>) -> worker;
task_mode(Mode) -> Mode.

validate_entry(Mode, {Module, Function})
        when (Mode =:= owngil orelse Mode =:= isolated), is_binary(Module), is_binary(Function) ->
    case lists:all(fun python_identifier/1, binary:split(Module, <<".">>, [global]))
         andalso python_identifier(Function) of
        true -> ok;
        _ -> {error, invalid_task_entry}
    end;
validate_entry(Mode, _) when Mode =:= owngil; Mode =:= isolated -> {error, invalid_task_entry};
validate_entry(Mode, _) -> {error, {unsupported_task_mode, Mode}}.

python_identifier(Name) ->
    %% ID_Start/Continue with Other_ID exceptions and NFKC closure (Python XID).
    %% U+2E2F is Pattern_Syntax despite its letter category.
    Start = <<"[\\p{L}\\p{Nl}_\\x{1885}\\x{1886}\\x{2118}\\x{212E}]">>,
    Continue = <<"[\\p{L}\\p{Nl}\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}"
                 "\\x{B7}\\x{387}\\x{1369}-\\x{1371}\\x{19DA}"
                 "\\x{200C}\\x{200D}\\x{2118}\\x{212E}\\x{30FB}\\x{FF65}]">>,
    Pattern = <<"\\A(?!.*\\x{2E2F})", Start/binary, Continue/binary, "*\\z">>,
    Options = [unicode, ucp, {capture, none}],
    try
        re:run(Name, Pattern, Options) =:= match andalso
        re:run(unicode:characters_to_nfkc_binary(Name), Pattern, Options) =:= match
    catch error:badarg -> false end.

init({Count, Bytes}) when is_integer(Count), Count > 0, is_integer(Bytes), Bytes > 0 ->
    process_flag(trap_exit, true),
    {ok, Sup} = py_supervision:start_link(#{strategy => one_for_one, intensity => 0,
        period => 1, mailbox => bounded, max_children => Count}),
    {ok, Control} = py_context:new(#{mode => worker, context_owner => self()}),
    Native = py_context:get_nif_ref(Control),
    Gate = py_nif:actor_gate_new(Count, Bytes),
    {ok, #{sup => Sup, control => Control, control_native => Native, gate => Gate, max => Count,
           jobs => #{}, starting => #{}, closed => false, closing => none, polling => false}}.

handle_call(gate, _, #{gate := Gate} = State) -> {reply, {ok, {self(), Gate}}, State};
handle_call(disposal, _, #{control_native := Native, jobs := Jobs, starting := Starting, gate := Gate} = State) ->
    py_nif:actor_gate_close(Gate),
    Reply = case {map_size(Jobs) + map_size(Starting), py_nif:actor_gate_info(Gate)} of
        {0, #{count := 0, unsettled := 0}} -> {ok, Native};
        _ -> {error, {uncertain_inflight, {unobserved_results, maps:keys(Jobs)}}}
    end,
    {reply, Reply, State#{closed := true}};
handle_call(info, _, #{gate := Gate, sup := Sup, jobs := Jobs, starting := Starting} = State) ->
    {reply, #{gate => py_nif:actor_gate_info(Gate), children => supervisor:which_children(Sup),
              contexts => [maps:get(ctx, Job) || Job <- maps:values(Jobs)],
              jobs => map_size(Jobs), starting => map_size(Starting)}, State};
handle_call({start_named, Mode, Gate, Ticket, Payload, Entry}, From, State) ->
    case validate_entry(Mode, Entry) of
        ok when is_binary(Payload) ->
            Token = erlang:unique_integer([positive]),
            begin_start(Gate, Ticket, Payload, [self(), Mode, Entry, Token, Ticket, Payload], From, State);
        ok ->
            py_nif:actor_ticket_reject(Ticket),
            {reply, {error, invalid_task_payload}, State};
        Error ->
            py_nif:actor_ticket_reject(Ticket),
            {reply, Error, State}
    end;
handle_call({start, Gate, Ticket, Payload, Factory}, From, State) ->
    begin_start(Gate, Ticket, Payload, [self(), Factory, Ticket, Payload], From, State);
handle_call({wait, Pid}, From, #{jobs := Jobs} = State) ->
    case maps:find(Pid, Jobs) of
        {ok, #{ready := true, result := Result}} ->
            {reply, Result, State#{jobs := maps:remove(Pid, Jobs)}};
        {ok, #{result := {error, {uncertain_inflight, _}} = Result} = Job} ->
            {reply, Result, State#{jobs := Jobs#{Pid := Job#{observed := true}}}};
        {ok, #{waiters := Waiters} = Job} ->
            {noreply, State#{jobs := Jobs#{Pid := Job#{waiters := [From | Waiters]}}}};
        error -> {reply, {error, unknown_task}, State}
    end;
handle_call({cancel, Pid}, _, #{jobs := Jobs, control := Control} = State) ->
    case maps:find(Pid, Jobs) of
        {ok, #{ready := false} = Job} ->
            {reply, ok, State#{jobs := Jobs#{Pid := request_cancel(Job, Control)}}};
        _ -> {reply, ok, State}
    end;
handle_call({isolated_context, Pid}, _, #{jobs := Jobs} = State) ->
    Reply = case maps:find(Pid, Jobs) of
        {ok, #{ready := true}} -> {error, task_finished};
        {ok, #{native := isolated, ctx := Ctx}} -> {ok, Ctx};
        {ok, _} -> {error, not_isolated};
        error -> {error, unknown_task}
    end,
    {reply, Reply, State};
handle_call({shutdown, Budget}, From, #{gate := Gate, jobs := Jobs, control := Control,
                                      closing := none} = State)
        when is_integer(Budget), Budget > 0 ->
    ok = py_nif:actor_gate_close(Gate),
    Deadline = make_ref(),
    Timer = erlang:send_after(Budget, self(), {deadline, Deadline}),
    Next = maps:map(fun(_, Job) -> request_cancel(Job, Control) end, Jobs),
    {noreply, queue_poll(State#{jobs := Next, closed := true, closing := {From, Timer, Deadline}})};
handle_call(_, _, State) -> {reply, {error, invalid_request}, State}.

begin_start(Gate, Ticket, Payload, Args, From,
            #{gate := Gate, jobs := Jobs, starting := Starting, max := Max,
              closed := false, sup := Sup} = State)
        when map_size(Jobs) + map_size(Starting) < Max ->
    Owner = self(),
    Ref = make_ref(),
    Id = make_ref(),
    Spec = #{id => Id, start => {py_task, start_link, Args},
             restart => temporary, shutdown => infinity},
    {_, Mon} = spawn_monitor(fun() ->
        Result = try
            case supervisor:start_child(Sup, Spec) of
                {ok, Pid} -> {ok, Pid, gen_server:call(Pid, info, infinity)};
                Error -> Error
            end
        catch Class:Reason -> {error, {Class, Reason}} end,
        Owner ! {task_started, Ref, Result}
    end),
    Pending = #{id => Id, mon => Mon, from => From, ticket => Ticket, bytes => byte_size(Payload)},
    {noreply, State#{starting := Starting#{Ref => Pending}}};
begin_start(_, Ticket, _, _, _, State) ->
    py_nif:actor_ticket_reject(Ticket),
    {reply, {error, task_slots_full_or_closed}, State}.

request_cancel(#{cancel_sent := false, ready := false,
                 object := {named, Token}, ctx := Ctx} = Job, _) ->
    spawn(fun() ->
        py_context:submit_await(Ctx, '_erlang_impl._tasks', cancel_entry, [Token], #{}, infinity)
    end),
    Job#{cancel_sent := true};
request_cancel(#{cancel_sent := false, ready := false, object := Object} = Job, Control) ->
    %% One bounded control RPC per admitted child. Never block this owner on
    %% Python's GIL: its shutdown timer must also work during a native C call.
    spawn(fun() ->
        py_context:call(Control, '_erlang_impl._tasks', request_cancel, [Object], #{}, infinity)
    end),
    Job#{cancel_sent := true};
request_cancel(Job, _) -> Job.

seal_unstarted(_, _, #{native := isolated} = Job, _) -> Job;
seal_unstarted(Pid, true, #{seal_sent := false, ticket := Ticket,
                          object := {named, Token}, ctx := Ctx} = Job, _) ->
    case py_nif:actor_ticket_info(Ticket) of
        complete -> Job;
        reaped -> Job;
        _ ->
            Owner = self(),
            spawn(fun() ->
                Result = py_context:submit_await(Ctx, '_erlang_impl._tasks', seal_entry,
                                                 [Token], #{}, infinity),
                Owner ! {sealed, Pid, Result}
            end),
            Job#{seal_sent := true}
    end;
seal_unstarted(Pid, true, #{seal_sent := false, ticket := Ticket, object := Object} = Job, Control) ->
    case py_nif:actor_ticket_info(Ticket) of
        complete -> Job;
        reaped -> Job;
        _ ->
            Owner = self(),
            spawn(fun() ->
                Result = py_context:call(Control, '_erlang_impl._tasks', seal, [Object], #{}, infinity),
                Owner ! {sealed, Pid, Result}
            end),
            Job#{seal_sent := true}
    end;
seal_unstarted(_, _, Job, _) -> Job.

reap_context(_, _, #{native := isolated} = Job) -> Job;
reap_context(Pid, true, #{ctx := Ctx, native := Native, reaping := false} = Job) ->
    Owner = self(),
    spawn(fun() -> Owner ! {reaped, Pid, py_context:reap_dead(Ctx, Native)} end),
    Job#{reaping := true};
reap_context(_, true, #{ctx := Ctx, native := Native, reaped := false} = Job) ->
    case py_nif:context_cleanup_status(Native) of
        clean -> clean = py_context:reap_dead(Ctx, Native), Job#{reaped := true};
        _ -> Job
    end;
reap_context(_, _, Job) -> Job.

fail_start(Ref, Error, #{starting := Starting, sup := Sup} = State) ->
    #{id := Id} = maps:get(Ref, Starting),
    Owner = self(),
    spawn(fun() ->
        Cleanup = case supervisor:terminate_child(Sup, Id) of
            ok -> ok;
            {error, not_found} -> ok;
            Other -> Other
        end,
        Owner ! {task_start_failed, Ref, Error, Cleanup}
    end),
    State.

uncertain_start(Ref, Reason, #{starting := Starting, gate := Gate} = State) ->
    #{from := From} = maps:get(Ref, Starting),
    py_nif:actor_gate_close(Gate),
    gen_server:reply(From, {error, {uncertain_inflight, Reason}}),
    State#{closed := true}.

queue_poll(#{polling := false} = State) ->
    erlang:send_after(5, self(), poll),
    State#{polling := true};
queue_poll(State) -> State.

handle_cast(_, State) -> {noreply, State}.
handle_info({task_started, Ref, Result}, #{starting := Starting, gate := Gate, jobs := Jobs} = State) ->
    #{id := Id, mon := Mon, from := From, ticket := Ticket, bytes := Bytes} = maps:get(Ref, Starting),
    demonitor(Mon, [flush]),
    case Result of
        {ok, Pid, {Ctx, Object, Native}} ->
            case py_nif:actor_ticket_commit(Ticket, Gate, Bytes) of
                ok ->
                    Job = #{id => Id, ctx => Ctx, native => Native, object => Object,
                            ticket => Ticket, mon => monitor(process, Pid), result => pending, waiters => [],
                            ready => false, down => false, reaping => false, reaped => false,
                            observed => false, cancel_sent => false, seal_sent => false, sealed => false},
                    Pid ! run,
                    gen_server:reply(From, {ok, Pid}),
                    {noreply, State#{starting := maps:remove(Ref, Starting), jobs := Jobs#{Pid => Job}}};
                Error -> {noreply, fail_start(Ref, Error, State)}
            end;
        Error -> {noreply, fail_start(Ref, Error, State)}
    end;
handle_info({task_start_failed, Ref, Error, ok}, #{starting := Starting} = State) ->
    #{ticket := Ticket, from := From} = maps:get(Ref, Starting),
    ok = py_nif:actor_ticket_reject(Ticket),
    gen_server:reply(From, Error),
    {noreply, queue_poll(State#{starting := maps:remove(Ref, Starting)})};
handle_info({task_start_failed, Ref, Error, Cleanup}, State) ->
    {noreply, uncertain_start(Ref, {Error, Cleanup}, State)};
handle_info({task_child_exited, Pid, Ctx, _Reason}, #{jobs := Jobs} = State) ->
    case maps:find(Pid, Jobs) of
        {ok, #{native := isolated, ctx := Ctx} = Job} ->
            {noreply, queue_poll(State#{jobs := Jobs#{Pid := Job#{reaped := true}}})};
        _ -> {noreply, State}
    end;
handle_info({work_result, Pid, Reply}, #{jobs := Jobs, gate := Gate} = State) ->
    case maps:find(Pid, Jobs) of
        {ok, #{result := pending, ticket := Ticket} = Job} ->
            {Result, Closed} = case {py_nif:actor_ticket_info(Ticket), Reply} of
                {complete, {ok, _}} -> {Reply, maps:get(closed, State)};
                {complete, {python_error, _}} -> {Reply, maps:get(closed, State)};
                {complete, {cancelled}} -> {Reply, maps:get(closed, State)};
                {complete, {remote_error, _, _}} -> {Reply, maps:get(closed, State)};
                {complete, {task_crashed, _}} -> {Reply, maps:get(closed, State)};
                _ -> py_nif:actor_gate_close(Gate), {{error, {uncertain_inflight, Reply}}, true}
            end,
            {noreply, queue_poll(State#{closed := Closed,
                jobs := Jobs#{Pid := Job#{result := Result}}})};
        _ -> {noreply, State}
    end;
handle_info({'DOWN', Mon, process, Pid, Reason}, #{jobs := Jobs, gate := Gate, starting := Starting} = State) ->
    case [Ref || {Ref, #{mon := M}} <- maps:to_list(Starting), M =:= Mon] of
        [Ref] -> {noreply, uncertain_start(Ref, {starter_died, Reason}, State)};
        [] ->
            case maps:find(Pid, Jobs) of
                {ok, #{mon := Mon, result := Previous} = Job} ->
                    Result = case Reason of normal -> Previous;
                        _ -> py_nif:actor_gate_close(Gate), {error, {uncertain_inflight, Reason}} end,
                    Closed = maps:get(closed, State) orelse Reason =/= normal,
                    {noreply, queue_poll(State#{closed := Closed,
                        jobs := Jobs#{Pid := Job#{down := true, result := Result}}})};
                _ -> {noreply, State}
            end
    end;
handle_info({sealed, Pid, {ok, Sealed}}, #{jobs := Jobs} = State) when is_boolean(Sealed) ->
    case maps:find(Pid, Jobs) of
        {ok, Job} -> {noreply, queue_poll(State#{jobs := Jobs#{Pid := Job#{sealed := Sealed}}})};
        error -> {noreply, State}
    end;
handle_info({sealed, Pid, _}, #{jobs := Jobs, gate := Gate} = State) ->
    case maps:is_key(Pid, Jobs) of
        true -> py_nif:actor_gate_close(Gate), {noreply, queue_poll(State#{closed := true})};
        false -> {noreply, State}
    end;
handle_info({reaped, Pid, _}, #{jobs := Jobs, gate := Gate} = State) ->
    case maps:find(Pid, Jobs) of
        {ok, #{ctx := Ctx, native := Native} = Job} ->
            case py_nif:context_cleanup_status(Native) of
                clean ->
                    clean = py_context:reap_dead(Ctx, Native),
                    {noreply, queue_poll(State#{jobs := Jobs#{Pid := Job#{reaped := true}}})};
                pending -> {noreply, queue_poll(State)};
                uncertain ->
                    py_nif:actor_gate_close(Gate),
                    {noreply, queue_poll(State#{closed := true})}
            end;
        error -> {noreply, State}
    end;
handle_info(poll, #{jobs := Jobs, closing := Closing, gate := Gate,
                    sup := Sup, control := Control} = State) ->
    Children = supervisor:which_children(Sup),
    Next = maps:fold(fun(Pid, Job, Acc) ->
        #{id := Id, ctx := Ctx, ticket := Ticket, down := Down,
          result := Result, waiters := Waiters, observed := Observed} = Job,
        Gone = Down andalso not lists:keymember(Id, 1, Children) andalso
                not is_process_alive(Ctx) andalso Result =/= pending,
        Sealing = seal_unstarted(Pid, Gone, Job, Control),
        TicketState = py_nif:actor_ticket_info(Ticket),
        Settled = TicketState =:= complete orelse TicketState =:= reaped,
        Ended = Gone andalso (Settled orelse maps:get(sealed, Sealing)),
        Reaped = reap_context(Pid, Ended, Sealing),
        Ready = Ended andalso maps:get(reaped, Reaped),
        case Ready andalso not Settled of
            true -> ok = py_nif:task_ticket_reap(Ticket, maps:get(native, Reaped));
            false -> ok
        end,
        Unknown = case Result of {error, {uncertain_inflight, _}} -> true; _ -> false end,
        case {Ready, Observed, Waiters, Unknown} of
            {true, true, _, _} -> Acc;
            {true, _, [_ | _], _} ->
                [gen_server:reply(From, Result) || From <- Waiters], Acc;
            {false, _, [_ | _], true} ->
                [gen_server:reply(From, Result) || From <- Waiters],
                Acc#{Pid => Reaped#{waiters := [], observed := true}};
            _ -> Acc#{Pid => Reaped#{ready := Ready}}
        end
    end, #{}, Jobs),
    #{count := Count, unsettled := Unsettled} = py_nif:actor_gate_info(Gate),
    AllReady = map_size(maps:get(starting, State)) =:= 0 andalso Count =:= 0 andalso Unsettled =:= 0 andalso
        lists:all(fun(#{ready := Ready}) -> Ready end, maps:values(Next)),
    NewClosing = case {AllReady, Closing} of
        {true, {From, Timer, _}} -> erlang:cancel_timer(Timer), gen_server:reply(From, ok), none;
        _ -> Closing
    end,
    NextState = State#{jobs := Next, closing := NewClosing, polling := false},
    {noreply, case AllReady of false -> queue_poll(NextState); true -> NextState end};
handle_info({deadline, Deadline}, #{closing := {From, _, Deadline}} = State) ->
    gen_server:reply(From, {error, {uncertain_inflight, shutdown_deadline}}),
    {noreply, State#{closing := none}};
handle_info({'EXIT', Sup, Reason}, #{sup := Sup} = State) -> {stop, Reason, State};
handle_info({'EXIT', Control, Reason}, #{control := Control} = State) ->
    {stop, {control_context_died, Reason}, State};
handle_info(_, State) -> {noreply, State}.

terminate(_, #{sup := Sup, control := Control, gate := Gate}) ->
    py_nif:actor_gate_close(Gate),
    unlink(Sup),
    case is_process_alive(Sup) of true -> gen_server:stop(Sup, shutdown, infinity); false -> ok end,
    py_context:destroy(Control).

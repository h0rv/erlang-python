-module(py_task).
-behaviour(gen_server).
-export([start_link/4, start_link/6, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Group, Factory, Ticket, Payload) ->
    gen_server:start_link(?MODULE, {Group, Factory, Ticket, Payload}, []).

start_link(Group, Mode, Entry, Token, Ticket, Payload) when Mode =:= owngil; Mode =:= isolated ->
    gen_server:start_link(?MODULE, {named, Group, Mode, Entry, Token, Ticket, Payload}, []).

init({named, Group, Mode, Entry, Token, Ticket, Payload}) ->
    Opts = case Mode of
        isolated ->
            process_flag(trap_exit, true),
            #{mode => isolated, restart => false, context_owner => self(),
              task_exit_observer => {Group, self()}};
        owngil -> #{mode => owngil, context_owner => self()}
    end,
    {ok, Ctx} = py_context:new(Opts),
    Native = case Mode of isolated -> isolated; owngil -> py_context:get_nif_ref(Ctx) end,
    {ok, none} = py_context:call(Ctx, '_erlang_impl._tasks', prepare_entry, [Token]),
    case Mode of isolated -> ok = py_context:start_loop(Ctx); owngil -> ok end,
    Mon = monitor(process, Ctx),
    {ok, #{group => Group, ctx => Ctx, native => Native, mon => Mon, mode => Mode,
           entry => Entry, token => Token, object => {named, Token},
           ticket => Ticket, payload => Payload}};
init({Group, Factory, Ticket, Payload}) ->
    {ok, Ctx} = py_context:new(#{mode => worker, managed_loop => dedicated, context_owner => self()}),
    Native = py_context:get_nif_ref(Ctx),
    {ok, Env} = py_context:create_local_env(Ctx),
    {ok, Empty} = py_context:eval_ref(Ctx, <<"()">>, #{}, Env),
    {ok, Kwargs} = py_context:eval_ref(Ctx, <<"{}">>, #{}, Env),
    {ok, Object} = py_context:apply_ref(Ctx, Factory, Empty, Kwargs, Env),
    {ok, Dispatch} = py_context:eval_ref(Ctx,
        <<"__import__('_erlang_impl._tasks', fromlist=['execute']).execute">>, #{}, Env),
    Mon = monitor(process, Ctx),
    {ok, #{group => Group, ctx => Ctx, native => Native, mon => Mon, env => Env,
           object => Object, dispatch => Dispatch, kwargs => Kwargs,
           ticket => Ticket, payload => Payload}}.

handle_call(info, _From, #{ctx := Ctx, object := Object, native := Native} = State) ->
    {reply, {Ctx, Object, Native}, State}.
handle_cast(_, State) -> {noreply, State}.

%% The group captures ownership and installs its monitor before sending run.
%% Cancellation goes through its separate control context, never this busy turn.
handle_info(run, #{mode := isolated, entry := {Module, Function}, token := Token,
                   ctx := Ctx, payload := Payload} = State) ->
    Reply = py_context:submit(Ctx, '_erlang_impl._tasks', execute_entry,
                              [Module, Function, Token, {bytes, Payload}]),
    case Reply of
        {ok, Ref} -> {noreply, State#{task_ref => Ref}};
        _ -> self() ! {named_result, Reply}, {noreply, State}
    end;
handle_info({async_result, Ref, Reply}, #{mode := isolated, task_ref := Ref} = State) ->
    handle_info({named_result, Reply}, State);
handle_info({isolated_child_exited, Ctx, Reason}, #{mode := isolated, ctx := Ctx} = State) ->
    crashed(Reason, State);
handle_info(run, #{entry := {Module, Function}, token := Token, ctx := Ctx,
                   payload := Payload} = State) ->
    ok = py_context:start_loop(Ctx),
    Owner = self(),
    spawn_link(fun() ->
        Reply = py_context:submit_await(Ctx, '_erlang_impl._tasks', execute_entry,
                                       [Module, Function, Token, {bytes, Payload}], #{}, infinity),
        Owner ! {named_result, Reply}
    end),
    {noreply, State};
handle_info({named_result, Reply}, #{entry := _, group := Group, ticket := Ticket} = State) ->
    Result = named_result(Reply, Ticket),
    Group ! {work_result, self(), Result},
    {stop, normal, State};
handle_info(run, #{ctx := Ctx, object := Object, group := Group,
                   ticket := Ticket, payload := Payload} = State) ->
    case py_context:call(Ctx, '_erlang_impl._tasks', dedicated, [Object]) of
        {ok, true} ->
            ok = py_context:start_loop(Ctx),
            Result = case py_context:submit_await(Ctx, '_erlang_impl._tasks', execute_owned,
                          [Object, Ticket, {bytes, Payload}], #{}, infinity) of
                {ok, {<<"ok">>, Bytes}} -> {ok, {bytes, Bytes}};
                {ok, {<<"python_error">>, Error}} -> {python_error, Error};
                Error -> Error
            end,
            Group ! {work_result, self(), Result},
            {stop, normal, State};
        {ok, false} -> run_shared(State)
    end;
handle_info({'DOWN', Mon, process, _, {child_exited, Reason}},
            #{mode := isolated, mon := Mon} = State) ->
    crashed(Reason, State);
handle_info({'DOWN', Mon, process, _, Reason}, #{mon := Mon} = State) ->
    {stop, {context_died, Reason}, State};
handle_info(_, State) -> {noreply, State}.

crashed(Reason, #{group := Group, ticket := Ticket} = State) ->
    ok = py_nif:task_ticket_complete(Ticket),
    Group ! {work_result, self(), {task_crashed, Reason}},
    {stop, normal, State}.

named_result({ok, {<<"ok">>, Bytes}}, Ticket) when is_binary(Bytes) ->
    ok = py_nif:task_ticket_complete(Ticket),
    {ok, {bytes, Bytes}};
named_result({ok, {<<"cancelled">>}}, Ticket) ->
    ok = py_nif:task_ticket_complete(Ticket),
    {cancelled};
named_result({ok, {<<"remote_error">>, Type, Message}}, Ticket)
        when is_binary(Type), is_binary(Message) ->
    ok = py_nif:task_ticket_complete(Ticket),
    {remote_error, Type, Message};
named_result(Error, _) -> Error.

run_shared(#{ctx := Ctx, env := Env, object := Object, dispatch := Dispatch,
                   kwargs := Kwargs, group := Group, ticket := Ticket, payload := Payload} = State) ->
    Result = try
        {ok, Args} = py_context:call(Ctx, '_erlang_impl._actor_data', arguments,
            [Object, Ticket, {bytes, Payload}], #{}, infinity),
        case py_context:apply_ref(Ctx, Dispatch, Args, Kwargs, Env, infinity) of
            {ok, Ref} ->
                case py_context:call(Ctx, '_erlang_impl._actor_data', response, [Ref], #{}, infinity) of
                    {ok, Bytes} -> {ok, {bytes, Bytes}};
                    Error -> Error
                end;
            Error -> Error
        end
    catch Class:Reason -> {error, {Class, Reason}} end,
    Group ! {work_result, self(), Result},
    {stop, normal, State}.

terminate(_, #{ctx := Ctx}) ->
    _ = py_context:stop_loop(Ctx),
    py_context:destroy(Ctx).

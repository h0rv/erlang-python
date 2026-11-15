-module(py_task).
-behaviour(gen_server).
-export([start_link/4, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Group, Factory, Ticket, Payload) ->
    gen_server:start_link(?MODULE, {Group, Factory, Ticket, Payload}, []).

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
handle_info({'DOWN', Mon, process, _, Reason}, #{mon := Mon} = State) ->
    {stop, {context_died, Reason}, State};
handle_info(_, State) -> {noreply, State}.

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

terminate(_, #{ctx := Ctx}) -> py_context:destroy(Ctx).

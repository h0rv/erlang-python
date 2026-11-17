%%% @doc Serial data actor dispatch through leased Python workers.
-module(py_data_actor).
-behaviour(gen_server).
-export([start_link/5, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Group, Id, Factory, Count, Bytes) ->
    gen_server:start_link(?MODULE, {Group, Id, Factory, Count, Bytes}, []).

init({Group, Id, Factory, Count, Bytes}) ->
    Ctx = py_worker_pool:checkout(undefined),
    try initialize(Group, Id, Factory, Count, Bytes, Ctx)
    after py_worker_pool:checkin(Ctx) end.

initialize(Group, Id, Factory, Count, Bytes, Ctx) ->
    {ok, Env} = py_context:create_local_env(Ctx),
    {ok, Args} = py_context:eval_ref(Ctx, <<"()">>, #{}, Env),
    {ok, Kwargs} = py_context:eval_ref(Ctx, <<"{}">>, #{}, Env),
    case py_context:apply_ref(Ctx, Factory, Args, Kwargs, Env) of
        {ok, LocalObject} ->
            {ok, LocalDispatch} = py_context:eval_ref(Ctx,
                <<"__import__('_erlang_impl._actor_data', fromlist=['dispatch_worker']).dispatch_worker">>, #{}, Env),
            {ok, Object} = py_context:call(Ctx, '_erlang_impl._actor_data', portable, [LocalObject], #{}),
            {ok, Dispatch} = py_context:call(Ctx, '_erlang_impl._actor_data', portable, [LocalDispatch], #{}),
            {ok, PortableKwargs} = py_context:call(Ctx, '_erlang_impl._actor_data', portable, [Kwargs], #{}),
            Gate = py_nif:actor_gate_new(Count, Bytes),
            Generation = erlang:unique_integer([monotonic, positive]),
            true = ets:insert(py_actor_generations,
                {{Group, Id}, self(), Generation, Gate}),
            {ok, #{ctx => Ctx, env => Env,
                   object => Object, gate => Gate, dispatch => Dispatch, kwargs => PortableKwargs}};
        Error -> {stop, Error}
    end.

handle_call({data, Gate, Ticket, Payload}, _From,
            #{ctx := Preferred, object := Object, gate := Gate, env := Env,
              dispatch := Dispatch, kwargs := Kwargs} = State) ->
    Ctx = py_worker_pool:checkout(Preferred),
    try
    %% Python owns completion through actual await and byte serialization.
    %% Killing this gen_server cannot release a still-running reservation.
    {ok, Args} = py_context:call(Ctx, '_erlang_impl._actor_data', arguments,
        [Object, Ticket, {bytes, Payload}], #{}, infinity),
    Reply = py_context:apply_ref(Ctx, Dispatch, Args, Kwargs, Env, infinity),
    Result = case Reply of
        {ok, Ref} ->
            case py_context:call(Ctx, '_erlang_impl._actor_data', response, [Ref], #{}, infinity) of
                {ok, Bytes} when is_binary(Bytes) -> {ok, {bytes, Bytes}};
                Other -> Other
            end;
        Other -> Other
    end,
    {reply, Result, State#{ctx := Ctx}}
    after py_worker_pool:checkin(Ctx) end;
handle_call(_, _From, State) -> {reply, {error, invalid_request}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

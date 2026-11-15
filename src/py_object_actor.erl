-module(py_object_actor).
-behaviour(gen_server).

-export([start_link/4, call/5, stop/1, register_callbacks/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

register_callbacks() ->
    py_callback:register('_actor_spawn', fun
        ([Factory, Methods, <<"unbounded">>]) when is_list(Methods), Methods =/= [] ->
            gen_server:start(?MODULE, {owned, Factory, Methods}, []);
        (_) -> {error, admission_unavailable}
    end),
    py_callback:register('_actor_call', fun([Pid, Method, Args, Kwargs]) ->
        call(Pid, Method, Args, Kwargs, infinity)
    end),
    py_callback:register('_actor_stop', fun([Pid]) ->
        case is_process_alive(Pid) of
            true -> stop(Pid);
            false -> ok
        end
    end),
    ok.

%% Deliberately unbounded native prototype. No default policy and no claim of
%% bounded admission. A separate native admission implementation owns tickets.
-spec start_link(py_context:context(), py_context:local_ref(),
                 [py_context:local_ref()], term()) -> {ok, pid()} | {error, term()}.
start_link(Ctx, Factory, Methods, unbounded) when is_list(Methods), Methods =/= [] ->
    gen_server:start_link(?MODULE, {Ctx, Factory, Methods}, []);
start_link(_Ctx, _Factory, _Methods, _Policy) ->
    {error, admission_unavailable}.

-spec call(pid(), py_context:local_ref(), py_context:local_ref(),
           py_context:local_ref(), timeout()) -> py_context:local_result().
call(Pid, Method, Args, Kwargs, Timeout) ->
    gen_server:call(Pid, {invoke, Method, Args, Kwargs}, Timeout).

stop(Pid) -> gen_server:stop(Pid).

init({owned, Factory, Methods}) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    case init({Ctx, Factory, Methods}) of
        {ok, State} -> {ok, State#{owned => true}};
        Error -> py_context:destroy(Ctx), Error
    end;
init({Ctx, Factory, Methods}) ->
    Mon = erlang:monitor(process, Ctx),
    {ok, Env} = py_context:create_local_env(Ctx),
    {ok, EmptyArgs} = py_context:eval_ref(Ctx, <<"()">>, #{}, Env),
    {ok, EmptyKwargs} = py_context:eval_ref(Ctx, <<"{}">>, #{}, Env),
    case py_context:apply_ref(Ctx, Factory, EmptyArgs, EmptyKwargs, Env) of
        {ok, Object} ->
            case register_methods(Ctx, Env, Object, Methods) of
                ok -> {ok, #{ctx => Ctx, monitor => Mon, env => Env,
                             object => Object, methods => Methods}};
                Error -> {stop, Error}
            end;
        Error -> {stop, Error}
    end.

register_methods(_Ctx, _Env, _Object, []) -> ok;
register_methods(Ctx, Env, Object, [Method | Rest]) ->
    Code = <<"(lambda state, method: None if ("
             "type(method) is __import__('types').FunctionType and "
             "__import__('inspect').iscoroutinefunction(method) and "
             "any(value is method for value in "
             "{name: value for base in reversed(type(state).__mro__) "
             "for name, value in vars(base).items()}.values())) "
             "else (_ for _ in ()).throw(ValueError('Not an async actor member')))(state, method)">>,
    case py_context:eval_ref(Ctx, Code, #{<<"state">> => Object, <<"method">> => Method}, Env) of
        {ok, _} -> register_methods(Ctx, Env, Object, Rest);
        Error -> Error
    end.

handle_call({invoke, Method, Args, Kwargs}, _From,
            #{ctx := Ctx, env := Env, object := Object, methods := Methods} = State) ->
    Result = case lists:member(Method, Methods) of
        false -> {error, method_not_registered};
        true ->
            case py_context:eval_ref(Ctx, <<"(state,) + args">>,
                                    #{<<"state">> => Object, <<"args">> => Args}, Env) of
                {ok, BoundArgs} -> py_context:apply_ref(Ctx, Method, BoundArgs, Kwargs, Env);
                Error -> Error
            end
    end,
    {reply, Result, State};
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_request}, State}.

terminate(_Reason, #{owned := true, ctx := Ctx}) ->
    py_context:destroy(Ctx);
terminate(_Reason, _State) -> ok.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({'DOWN', Mon, process, _Ctx, Reason}, #{monitor := Mon} = State) ->
    {stop, {context_died, Reason}, State};
handle_info(_Message, State) -> {noreply, State}.

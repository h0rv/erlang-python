%%% @doc Serial data actor dispatch through leased Python workers.
-module(py_data_actor).
-behaviour(gen_server).
-export([start_link/5, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Group, Id, Factory, Count, Bytes) ->
    gen_server:start_link(?MODULE, {Group, Id, Factory, Count, Bytes}, []).

init({Group, Id, Factory, Count, Bytes}) ->
    Gate = py_nif:actor_gate_new(Count, Bytes),
    Object = py_nif:actor_object_new(),
    ok = py_actor_registry:own(self(), Gate, Object),
    Ctx = py_worker_pool:checkout(undefined),
    try
        case py_context:call(Ctx, '_erlang_impl._actor_data', initialize,
                             [Factory, Object], #{}, infinity) of
            {ok, _} ->
                Generation = erlang:unique_integer([monotonic, positive]),
                true = ets:insert(py_actor_generations,
                    {{Group, Id}, self(), Generation, Gate}),
                {ok, #{ctx => Ctx, object => Object, gate => Gate}};
            Error -> {stop, Error}
        end
    after py_worker_pool:checkin(Ctx) end.

handle_call({data, Gate, Ticket, Payload}, _From,
            #{ctx := Preferred, object := Object, gate := Gate} = State) ->
    Ctx = py_worker_pool:checkout(Preferred),
    try
    Reply = case py_context:call(Ctx, '_erlang_impl._actor_data', call,
        [Object, Ticket, {bytes, Payload}], #{}, infinity) of
        {ok, {true, Bytes}} when is_binary(Bytes) -> {ok, {bytes, Bytes}};
        {ok, {false, Error}} -> {python_error, Error};
        Other -> Other
    end,
    {reply, Reply, State#{ctx := Ctx}}
    after py_worker_pool:checkin(Ctx) end;
handle_call(_, _From, State) -> {reply, {error, invalid_request}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

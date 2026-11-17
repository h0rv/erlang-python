-module(py_durable_task_worker).
-behaviour(gen_server).
-export([start_link/2, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Queue, Lease) -> gen_server:start_link(?MODULE, {Queue, Lease}, []).
init({Queue, Lease}) ->
    process_flag(trap_exit, true),
    {ok, Ctx} = py_context:new(#{mode => worker, managed_loop => dedicated,
                               context_owner => self()}),
    ok = py_context:start_loop(Ctx),
    self() ! claim,
    {ok, #{queue => Queue, lease => Lease, ctx => Ctx, helper => undefined, item => none}}.

handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(claim, #{queue := Queue, lease := Lease} = S) ->
    Owner = self(),
    Helper = spawn_link(fun() ->
        Owner ! {claimed, self(), py_durable_queue:claim(Queue, Lease, 30000)}
    end),
    {noreply, S#{helper := Helper}};
handle_info({claimed, Helper, {ok, Id, Token, _, Record}}, #{helper := Helper, ctx := Ctx} = S) ->
    Owner = self(),
    Runner = spawn_link(fun() -> Owner ! {result, self(), execute(Ctx, Record)} end),
    {noreply, S#{helper := Runner, item := {Id, Token}}};
handle_info({claimed, Helper, Result}, #{helper := Helper} = S) ->
    Delay = case Result of empty -> 0; _ -> 100 end,
    erlang:send_after(Delay, self(), claim),
    {noreply, S#{helper := undefined}};
handle_info({result, Helper, Result}, #{helper := Helper, item := {Id, Token}} = S) ->
    case Result of
        {ok, Bin} when is_binary(Bin) -> py_durable_queue:ack(Id, Token);
        _ -> py_durable_queue:release(Id, Token)
    end,
    Delay = case Result of {ok, Bin2} when is_binary(Bin2) -> 0; _ -> 100 end,
    erlang:send_after(Delay, self(), claim),
    {noreply, S#{helper := undefined, item := none}};
handle_info({'EXIT', Helper, Reason}, #{helper := Helper} = S) when Reason =/= normal ->
    {stop, {helper_died, Reason}, S};
handle_info({'EXIT', Ctx, Reason}, #{ctx := Ctx} = S) -> {stop, {context_died, Reason}, S};
handle_info(_, S) -> {noreply, S}.

execute(Ctx, Record) ->
    try binary_to_term(Record, [safe]) of
        {durable_task, 1, Module, Function, Payload}
          when is_binary(Module), is_binary(Function), is_binary(Payload) ->
            py_context:submit_await(Ctx, Module, Function, [{bytes, Payload}], #{}, infinity);
        _ -> {error, invalid_task_record}
    catch Class:Reason -> {error, {Class, Reason}} end.

terminate(_, #{ctx := Ctx, helper := Helper, item := Item}) ->
    case Helper of undefined -> ok; _ -> unlink(Helper), exit(Helper, kill) end,
    try py_context:destroy(Ctx) catch _:_ -> ok end,
    case Item of
        none -> ok;
        {Id, Token} -> try py_durable_queue:release(Id, Token) catch _:_ -> ok end
    end,
    ok.

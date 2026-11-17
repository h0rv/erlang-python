-module(py_durable_tasks).
%% At-least-once execution. Results are discarded after acknowledgement.
%% Leases are not renewed: bodies can overlap after expiry or node loss.
%% Replicated non-majority Mnesia does not provide partition safety.
-behaviour(supervisor).
-export([start_link/0, init/1, register_callbacks/0, submit/5, serve/3, stop/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) -> {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, []}}.

register_callbacks() ->
    py_callback:register('_tasks_submit', fun([Queue, Key, Module, Function, Payload]) ->
        submit(Queue, case Key of none -> undefined; _ -> Key end, Module, Function, Payload)
    end),
    py_callback:register('_tasks_serve', fun([Queue, Concurrency, Lease]) ->
        serve(Queue, Concurrency, Lease)
    end),
    py_callback:register('_tasks_stop', fun([Queue]) -> stop(Queue) end), ok.

%% The queue's 1 MiB limit includes the serialized module, function and payload.
submit(Queue, Key, Module, Function, Payload)
  when is_binary(Module), byte_size(Module) > 0, is_binary(Function),
       byte_size(Function) > 0, is_binary(Payload) ->
    py_durable_queue:put(Queue, Key, term_to_binary({durable_task, 1, Module, Function, Payload}));
submit(_, _, _, _, _) -> {error, invalid_argument}.

serve(Queue, Concurrency, Lease) when is_binary(Queue), is_integer(Concurrency),
    Concurrency > 0, Concurrency =< 1024, is_integer(Lease), Lease > 0, Lease =< 4294967295 ->
    case py_durable_queue:is_open(Queue) of
        false -> {error, not_open};
        true ->
            case supervisor:start_child(?MODULE, #{id => Queue,
                start => {py_durable_task_pool, start_link, [Queue, Concurrency, Lease]},
                type => supervisor, shutdown => infinity}) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> {error, already_serving};
                Error -> Error
            end
    end;
serve(_, _, _) -> {error, invalid_argument}.

stop(Queue) when is_binary(Queue) ->
    case supervisor:terminate_child(?MODULE, Queue) of
        ok -> supervisor:delete_child(?MODULE, Queue);
        {error, not_found} -> ok;
        Error -> Error
    end;
stop(_) -> {error, invalid_argument}.

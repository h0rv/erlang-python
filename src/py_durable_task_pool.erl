-module(py_durable_task_pool).
-behaviour(supervisor).
-export([start_link/3, init/1]).

start_link(Queue, Concurrency, Lease) ->
    supervisor:start_link(?MODULE, {Queue, Concurrency, Lease}).
init({Queue, Concurrency, Lease}) ->
    Children = [#{id => I, start => {py_durable_task_worker, start_link, [Queue, Lease]},
                  shutdown => 5000} || I <- lists:seq(1, Concurrency)],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Children}}.

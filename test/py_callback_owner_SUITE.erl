-module(py_callback_owner_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         nested_dedicated/1, nested_temporary_shared/1, shared_driver_transition/1,
         late_reply_after_close/1]).

all() -> [shared_driver_transition, nested_dedicated, nested_temporary_shared,
          late_reply_after_close].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python), Config.
end_per_suite(_) -> application:stop(erlang_python).

shared_driver_transition(_) ->
    {ok, C} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    ok = py_context:exec(C, iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [Dir]))),
    try
        {ok, 42} = py_context:submit_await(C, asyncio, sleep, [0.001],
                                         #{<<"result">> => 42}, 5000),
        %% Inspect the actual native resource owner, not asyncio's thread cache.
        {ok, Owner} = py_context:eval(C,
            <<"id(__import__('py_event_loop')._get_loop_ref())">>),
        ok = py_context:start_loop(C),
        {ok, Owner} = py_context:submit_await(C, py_test_callback_owner, owner_identity,
            [], #{}, 5000),
        ok = py_context:stop_loop(C)
    after py_context:stop(C) end.

late_reply_after_close(_) ->
    {ok, C} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    ok = py_context:exec(C, iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [Dir]))),
    Parent = self(),
    ok = py_callback:register(composition_held, fun([]) ->
        Parent ! {held_writer, self()},
        receive release -> 99 after 5000 -> error(writer_barrier_timeout) end
    end),
    ok = py_callback:register(composition_echo, fun([Value]) -> Value end),
    try
        ok = py_context:start_loop(C),
        {ok, true} = py_context:submit_await(C, py_test_callback_owner, hold_callback, [], #{}, 1000),
        Writer = receive {held_writer, Pid} -> Pid after 1000 -> error(no_writer) end,
        ok = py_context:stop_loop(C),
        {ok, true} = py_context:call(C, py_test_callback_owner, check_abandoned, []),
        ok = py_context:start_loop(C),
        %% Observe the actual response NIF return, not a guessed settling delay.
        1 = erlang:trace_pattern({py_nif, async_callback_response, 3},
                                 [{'_', [], [{return_trace}]}], [local]),
        1 = erlang:trace(Writer, true, [call, {tracer, self()}]),
        Writer ! release,
        receive
            {trace, Writer, return_from, {py_nif, async_callback_response, 3}, ok} -> ok
        after 1000 -> error(no_late_response_ack) end,
        erlang:trace_pattern({py_nif, async_callback_response, 3}, false, [local]),
        {ok, 42} = py_context:submit_await(C, py_test_callback_owner, echo_after_close, [], #{}, 1000),
        ok = py_context:stop_loop(C)
    after
        erlang:trace_pattern({py_nif, async_callback_response, 3}, false, [local]),
        py_callback:unregister(composition_held),
        py_callback:unregister(composition_echo),
        py_context:stop(C)
    end.

nested_dedicated(_) -> nested(dedicated).
nested_temporary_shared(_) -> nested(shared).
nested(Mode) ->
    {ok, C} = py_context:new(#{mode => worker, managed_loop => Mode}),
    Dir = filename:dirname(code:which(?MODULE)),
    ok = py_context:exec(C, iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p)", [Dir]))),
    Parent = self(),
    ok = py_callback:register(composition_enter, fun([Group]) ->
        #{jobs := Jobs} = sys:get_state(Group),
        [{Task, #{ctx := Context, native := Native}}] = maps:to_list(Jobs),
        Parent ! {captured, Task, Context, Native},
        ok
    end),
    try
        case Mode of dedicated -> ok = py_context:start_loop(C); shared -> ok end,
        {ok, true} = py_context:submit_await(C, py_test_callback_owner, nested, [], #{}, 10000),
        receive {captured, Task, Context, Native} ->
            false = is_process_alive(Task),
            false = is_process_alive(Context),
            clean = py_nif:context_cleanup_status(Native)
        after 1000 -> error(missing_context_identity) end,
        case Mode of dedicated -> ok = py_context:stop_loop(C); shared -> ok end
    after
        py_callback:unregister(composition_enter),
        py_context:stop(C)
    end.

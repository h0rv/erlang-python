-module(py_actor_controls_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         generations/1, cancelled_body/1, close_cancelled/1,
         temporary_fault/1, crash_cancelled/1]).

all() -> [generations, cancelled_body, close_cancelled, temporary_fault, crash_cancelled].
init_per_suite(Config) ->
    Config1 = py_ct_env:override(Config, #{num_contexts => 1, event_loop_pool_size => 1}),
    {ok, _} = application:ensure_all_started(erlang_python),
    Config1.

end_per_suite(Config) ->
    ok = application:stop(erlang_python),
    py_ct_env:restore(Config).

generations(_) -> probe(generations).
cancelled_body(_) -> probe(cancelled_body).
close_cancelled(_) -> probe(close_cancelled).
temporary_fault(_) -> probe(temporary_fault).
crash_cancelled(_) -> probe(crash_cancelled).

probe(Function) ->
    {ok, Ctx} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    try
        ok = py_context:exec(Ctx, iolist_to_binary(io_lib:format(
            "import sys; sys.path.insert(0, ~p)", [Dir]))),
        ok = py_context:start_loop(Ctx),
        {ok, true} = py_context:submit_await(Ctx, py_test_actor_controls,
                                            Function, [], #{}, 15000),
        ok = py_context:stop_loop(Ctx, 1000),
        receive {py_loop_exit, Ctx, _} -> ok after 5000 -> error(loop_survived) end
    after py_context:destroy(Ctx) end.

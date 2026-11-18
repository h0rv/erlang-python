-module(py_readiness_capacity_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         poll_leases/1, failed_dup/1, reserved_events/1]).

all() -> [poll_leases, failed_dup, reserved_events].

init_per_suite(Config) ->
    Config1 = py_ct_env:override(Config, #{num_contexts => 1, event_loop_pool_size => 1}),
    {ok, _} = application:ensure_all_started(erlang_python),
    Config1.

end_per_suite(Config) ->
    ok = application:stop(erlang_python),
    py_ct_env:restore(Config).

poll_leases(_) -> run_case(poll_leases).
failed_dup(_) -> run_case(failed_dup).
reserved_events(_) -> run_case(reserved_events).

run_case(Function) ->
    {ok, Context} = py_context:new(#{mode => worker}),
    Dir = filename:dirname(code:which(?MODULE)),
    try
        ok = py_context:exec(Context, iolist_to_binary(io_lib:format(
            "import sys; sys.path.insert(0, ~p)", [Dir]))),
        case py_context:submit_await(Context, py_test_readiness_capacity,
                                    Function, [], #{}, 30000) of
            {ok, true} -> ok;
            {ok, Reason} when is_binary(Reason) -> {skip, Reason};
            Other -> error({capacity_regression, Other})
        end
    after py_context:stop(Context) end.

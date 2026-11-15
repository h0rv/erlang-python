#!/usr/bin/env escript
%%! -noshell

main([BeamthonRoot]) ->
    Root = filename:absname(BeamthonRoot),
    "beamthon-supervision" = filename:basename(Root),
    NativeRoot = filename:join(filename:dirname(Root), "erlang-python-supervision"),
    {ok, Checkout} = file:read_link(filename:join([Root, "_checkouts", "erlang_python"])),
    NativeRoot = filename:absname(Checkout, filename:join(Root, "_checkouts")),
    Ebin = filename:join([Root, "_build", "default", "checkouts", "erlang_python", "ebin"]),
    true = code:add_patha(Ebin),
    {ok, py_supervision_demo, Binary} = compile:file(
        filename:join([NativeRoot, "examples", "py_supervision_demo.erl"]),
        [binary, warnings_as_errors]),
    {module, py_supervision_demo} = code:load_binary(py_supervision_demo, "demo", Binary),
    {ok, _} = application:ensure_all_started(erlang_python),
    try run(Root)
    after application:stop(erlang_python) end;
main(_) ->
    io:format(standard_error, "Usage: escript run_supervision.escript BEAMTHON_OWN_CHECKOUT~n", []),
    halt(2).

run(Root) ->
    process_flag(trap_exit, true),
    ok = py_supervision_demo:register_callbacks(),
    {ok, Events} = py_channel:new(#{max_size => 4096}),
    try
        {ok, Parent} = py_supervision:start_link(#{
            strategy => one_for_one, intensity => 3, period => 5,
            mailbox => unbounded, max_children => unbounded}),
        Ref = monitor(process, Parent),
        try run_python(Root, Parent, Events)
        after
            ok = gen_server:stop(Parent, shutdown, 3000),
            receive {'DOWN', Ref, process, Parent, shutdown} ->
                io:format("root shutdown confirmed~n")
            after 1000 -> erlang:error(root_shutdown_not_confirmed) end
        end
    after py_channel:close(Events) end.

run_python(Root, Parent, Events) ->
    {ok, Context} = py_context:new(#{mode => worker}),
    try
        ok = py:exec(Context, iolist_to_binary(io_lib:format(
            "import sys; sys.path[:0] = [~p, ~p]",
            [filename:join(Root, "src"), filename:join(Root, "examples")]))),
        ok = py_context:start_loop(Context),
        case py_context:submit_await(
            Context, 'supervision.main', main, [Parent, Events], #{}, 15000) of
            {ok, true} -> ok;
            Error -> erlang:error({example_failed, Error})
        end,
        ok = py_context:stop_loop(Context, 2000)
    after py_context:stop(Context) end.

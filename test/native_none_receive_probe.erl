%%% Compile only this probe; use the parent's existing native runtime build.
-module(native_none_receive_probe).
-export([run/0]).

run() ->
    try
        {ok, _} = application:ensure_all_started(erlang_python),
        ok = py:exec(<<"import test_native_none_receive as native_none_probe">>),
        Results = lists:map(fun run_case/1, [false, true]),
        case Results of
            [{ok, true}, {ok, true}] ->
                io:format("NATIVE_NONE_RECEIVE_PASS 2 cases~n"),
                halt(0);
            _ -> halt(1)
        end
    catch
        Class:Reason:Stack ->
            io:format("NATIVE_NONE_RECEIVE_FAIL ~p:~p~n~p~n", [Class, Reason, Stack]),
            halt(1)
    end.

run_case(NativeOnly) ->
    {ok, Channel} = py_channel:new(),
    try
        Result = py:eval(
            <<"native_none_probe.run_case(channel, native_only=native_only)">>,
            #{<<"channel">> => Channel, <<"native_only">> => NativeOnly}
        ),
        io:format("native_only=~p result=~p~n", [NativeOnly, Result]),
        Result
    after
        py_channel:close(Channel)
    end.

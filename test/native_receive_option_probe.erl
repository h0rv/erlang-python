%%% Focused native_only integration probes. Compile this module alone and run
%%% against an existing erlang_python ebin/NIF build. No rebar build is needed.
-module(native_receive_option_probe).
-export([run/0]).

run() ->
    try
        {ok, _} = application:ensure_all_started(erlang_python),
        ok = py:exec(<<"import test_native_receive_option as native_probe">>),
        io:format("OTP=~s~nPython/source=~p~n", [
            erlang:system_info(otp_release),
            py:eval(<<"native_probe.environment()">>)
        ]),
        Cases = [
            unsupported_empty, unsupported_queued, ordinary_fallback,
            immediate, delayed, native_spurious, default_spurious,
            cancellation, cancellation_after_spurious,
            closure, closed_drain, duplicate_waiter
        ],
        lists:foreach(fun run_case/1, Cases),
        io:format("NATIVE_RECEIVE_OPTION_PASS ~p cases~n", [length(Cases)]),
        halt(0)
    catch
        Class:Reason:Stack ->
            io:format("NATIVE_RECEIVE_OPTION_FAIL ~p:~p~n~p~n", [Class, Reason, Stack]),
            halt(1)
    end.

run_case(Name) ->
    {ok, Channel} = py_channel:new(),
    try
        Result = py:eval(<<"native_probe.run_case(name, channel)">>, #{
            <<"name">> => atom_to_binary(Name),
            <<"channel">> => Channel
        }),
        io:format("~p=~p~n", [Name, Result]),
        {ok, true} = Result
    after
        py_channel:close(Channel)
    end.

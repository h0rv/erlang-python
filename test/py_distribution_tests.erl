-module(py_distribution_tests).
-include_lib("eunit/include/eunit.hrl").

with_server(Fun) ->
    Config = #{<<"capacity">> => 2, <<"max_bytes">> => 3},
    {ok, Server} = gen_server:start({local, py_distribution}, py_distribution,
                                  [Config, #{}], []),
    try
        #{<<"status">> := <<"ok">>} = local(#{<<"op">> => <<"register">>, <<"definition">> => <<"double">>}),
        Fun()
    after gen_server:stop(Server) end.

remote(Request) ->
    json:decode(py_distribution:request(iolist_to_binary(json:encode(Request)))).
local(Request) ->
    json:decode(gen_server:call(py_distribution, {local, Request})).
snapshot() -> remote(#{<<"op">> => <<"snapshot">>}).
incarnation() -> maps:get(<<"incarnation">>, maps:get(<<"identity">>, snapshot())).
reserve(Inc, Id, Payload) ->
    remote(#{<<"op">> => <<"reserve">>, <<"incarnation">> => Inc,
             <<"id">> => Id, <<"definition">> => <<"double">>,
             <<"size">> => byte_size(Payload),
             <<"digest">> => binary:encode_hex(crypto:hash(sha256, Payload), lowercase)}).
job(Op, Inc, Token) -> #{<<"op">> => Op, <<"incarnation">> => Inc, <<"token">> => Token}.
status(R) -> maps:get(<<"status">>, R).

admission_bytes_and_conflict_test() -> with_server(fun() ->
    Inc = incarnation(),
    First = reserve(Inc, <<"one">>, <<"12">>),
    ?assertEqual(<<"ok">>, status(First)),
    ?assertEqual(<<"overloaded">>, status(reserve(Inc, <<"too-many-bytes">>, <<"34">>))),
    ?assertEqual(<<"duplicate">>, status(reserve(Inc, <<"one">>, <<"12">>))),
    ?assertEqual(<<"conflict">>, status(reserve(Inc, <<"one">>, <<"xx">>))),
    Second = reserve(Inc, <<"two">>, <<"3">>),
    ?assertEqual(<<"ok">>, status(Second)),
    ?assertEqual(2, maps:get(<<"count">>, snapshot())),
    Token = maps:get(<<"token">>, First),
    ?assertEqual(<<"conflict">>, status(remote((job(<<"submit">>, Inc, Token))#{<<"payload">> => <<"xx">>}))),
    ?assertEqual(<<"invalid_phase">>, status(remote(job(<<"ack">>, Inc, Token)))),
    ?assertEqual(2, maps:get(<<"count">>, snapshot()))
end).

accepted_credit_survives_expiry_cancel_and_observation_test() -> with_server(fun() ->
    Inc = incarnation(),
    Token = maps:get(<<"token">>, reserve(Inc, <<"queued">>, <<"12">>)),
    ?assertEqual(<<"ok">>, status(remote((job(<<"submit">>, Inc, Token))#{<<"payload">> => <<"12">>}))),
    ?assertEqual(<<"pending">>, status(remote(job(<<"cancel">>, Inc, Token)))),
    ?assertEqual(<<"pending">>, status(remote(job(<<"result">>, Inc, Token)))),
    timer:sleep(1100),
    ?assertEqual(1, maps:get(<<"count">>, snapshot())),
    ?assertEqual(<<"overloaded">>, status(reserve(Inc, <<"still-charged">>, <<"34">>))),
    ?assertEqual(<<"invalid_phase">>, status(remote(job(<<"ack">>, Inc, Token)))),
    ?assertEqual(<<"unknown_operation">>, status(remote(#{<<"op">> => <<"next">>}))),
    ?assertEqual(<<"unknown_operation">>, status(remote(#{<<"op">> => <<"register">>, <<"definition">> => <<"double">>}))),
    ?assertEqual(<<"ok">>, status(local(#{<<"op">> => <<"close_admission">>}))),
    ?assertEqual(<<"admission_closed">>, status(reserve(Inc, <<"closed">>, <<"3">>))),
    ?assertEqual(1, maps:get(<<"count">>, snapshot())),
    ?assertEqual(<<"unknown_operation">>, status(remote((job(<<"complete">>, Inc, Token))#{<<"result">> => <<"forged">>})))
end).

unsent_expiry_and_stale_ack_test() -> with_server(fun() ->
    Inc = incarnation(),
    Token = maps:get(<<"token">>, reserve(Inc, <<"unsent">>, <<"12">>)),
    ?assertEqual(<<"stale">>, status(remote(job(<<"ack">>, <<"old-generation">>, Token)))),
    ?assertEqual(1, maps:get(<<"count">>, snapshot())),
    timer:sleep(1100),
    ?assertEqual(0, maps:get(<<"count">>, snapshot())),
    ?assertEqual(<<"unknown_token">>, status(remote((job(<<"submit">>, Inc, Token))#{<<"payload">> => <<"12">>}))),
    ?assertEqual(<<"oversized">>, status(json:decode(py_distribution:request(binary:copy(<<"x">>, 8193))))),
    ?assertEqual(<<"unknown_operation">>, status(local(#{<<"op">> => <<"arbitrary_mfa">>})))
end).

event_buffer_exposes_overflow_test() -> with_server(fun() ->
    [whereis(py_distribution) ! {nodeup, 'owned@127.0.0.1', []} || _ <- lists:seq(1, 35)],
    S = snapshot(),
    ?assertEqual(32, length(maps:get(<<"events">>, S))),
    ?assertEqual(3, maps:get(<<"events_dropped">>, S))
end).

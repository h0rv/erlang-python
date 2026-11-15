-module(py_distribution_tests).
-include_lib("eunit/include/eunit.hrl").

with_server(Fun) -> with_server(#{<<"capacity">> => 2, <<"max_bytes">> => 3}, Fun).
with_server(Config, Fun) ->
    {ok, Server} = gen_server:start({local, py_distribution}, py_distribution,
                                  [Config, #{<<"b">> => node()}], []),
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

mailbox_payloads(Server) ->
    {messages, Messages} = process_info(Server, messages),
    lists:flatmap(fun
        ({'$gen_call', _, {ingress, _, _, Payload}}) -> [Payload];
        ({'$gen_call', _, {remote, #{<<"op">> := <<"submit">>, <<"payload">> := Payload}}}) -> [Payload];
        (_) -> []
    end, Messages).

wait_reverse_barrier(Server, Deadline) ->
    {messages, Messages} = process_info(Server, messages),
    case lists:any(fun
        ({'$gen_call', _, {remote, #{<<"op">> := <<"ack_receipt">>}}}) -> true;
        (_) -> false
    end, Messages) of
        true -> ok;
        false ->
            ?assert(erlang:monotonic_time(millisecond) < Deadline),
            receive after 1 -> wait_reverse_barrier(Server, Deadline) end
    end.

receive_reply(Tag) ->
    receive {Tag, Reply} -> Reply after 2000 -> error({missing_reply, Tag}) end.

wait_payload(Server, Deadline) ->
    case mailbox_payloads(Server) of
        [] ->
            ?assert(erlang:monotonic_time(millisecond) < Deadline),
            receive after 1 -> wait_payload(Server, Deadline) end;
        Payloads -> Payloads
    end.

%% Same three actual copies as the reviewer, not mocked enqueue counters.
atomic_ingress_precedes_application_mailbox_test() ->
  with_server(#{<<"capacity">> => 1, <<"max_bytes">> => 2}, fun() ->
    Inc = incarnation(), Server = whereis(py_distribution), Owner = self(),
    Token = maps:get(<<"token">>, reserve(Inc, <<"one">>, <<"12">>)),
    spawn(fun() -> remote(#{<<"op">> => <<"receipt">>, <<"id">> => <<"barrier">>,
                            <<"ack_alias">> => <<"b">>}) end),
    wait_reverse_barrier(Server, erlang:monotonic_time(millisecond) + 500),
    Submit = (job(<<"submit">>, Inc, Token))#{<<"payload">> => <<"12">>},
    %% Invalid inputs must return BEFORE the handler leaves its reverse-ACK wait.
    ?assertEqual(<<"conflict">>, status(remote(Submit#{<<"payload">> := <<"xxx">>}))),
    ?assertEqual(<<"conflict">>, status(remote(Submit#{<<"payload">> := <<"xx">>}))),
    ?assertEqual(<<"unknown_token">>, status(remote(Submit#{<<"token">> := <<"missing">>}))),
    ?assertEqual(<<"stale">>, status(remote(Submit#{<<"incarnation">> := <<"old">>}))),
    ?assertEqual(<<"oversized">>, status(json:decode(py_distribution:request(binary:copy(<<"x">>, 8193))))),
    [spawn(fun() -> Owner ! {duplicate, remote(Submit)} end) || _ <- lists:seq(1, 3)],
    Early = [status(receive_reply(duplicate)) || _ <- lists:seq(1, 2)],
    ?assertEqual([<<"invalid_phase">>, <<"invalid_phase">>], Early),
    Payloads = wait_payload(Server, erlang:monotonic_time(millisecond) + 200),
    ?assertEqual(1, length(Payloads)),
    ?assertEqual(2, lists:sum([byte_size(P) || P <- Payloads])),
    io:format("APPLICATION_MAILBOX_PAYLOADS=~p BYTES=2~n", [length(Payloads)]),
    Replies = Early ++ [status(receive_reply(duplicate))],
    ?assertEqual([<<"invalid_phase">>, <<"invalid_phase">>, <<"ok">>], lists:sort(Replies)),
    timer:sleep(50),
    ?assertEqual(1, maps:get(<<"count">>, snapshot())),
    ?assertEqual(<<"pending">>, status(remote(job(<<"cancel">>, Inc, Token)))),
    ?assertEqual(<<"invalid_phase">>, status(remote(job(<<"ack">>, Inc, Token)))),
    ?assertEqual(<<"overloaded">>, status(reserve(Inc, <<"charged">>, <<"34">>)))
end).

%% Simulate the crash window between the atomic claim and send. Never free it.
claimed_without_handoff_is_unknown_not_expirable_test() -> with_server(fun() ->
    Inc = incarnation(), Token = maps:get(<<"token">>, reserve(Inc, <<"lost-handoff">>, <<"12">>)),
    [Row] = ets:lookup(py_distribution, Token),
    Claimed = setelement(6, Row, claimed),
    ?assertEqual(1, ets:select_replace(py_distribution, [{Row, [], [{const, Claimed}]}])),
    ?assertEqual(<<"uncertain">>, status(remote(job(<<"result">>, Inc, Token)))),
    timer:sleep(1100),
    ?assertEqual(1, maps:get(<<"count">>, snapshot())),
    ?assertEqual(<<"invalid_phase">>, status(remote((job(<<"submit">>, Inc, Token))#{<<"payload">> => <<"12">>}))),
    ?assertEqual(<<"invalid_phase">>, status(remote(job(<<"ack">>, Inc, Token)))),
    ?assertEqual(<<"overloaded">>, status(reserve(Inc, <<"not-released">>, <<"34">>))),
    ?assertEqual(<<"ok">>, status(local(#{<<"op">> => <<"close_admission">>}))),
    ?assertEqual(1, maps:get(<<"count">>, snapshot()))
end).

unclaimed_expiry_wins_cas_test() -> with_server(fun() ->
    Inc = incarnation(), Token = maps:get(<<"token">>, reserve(Inc, <<"unsent-cas">>, <<"12">>)),
    [Row] = ets:lookup(py_distribution, Token),
    timer:sleep(1100),
    ?assertEqual(0, maps:get(<<"count">>, snapshot())),
    ?assertEqual(0, ets:select_replace(py_distribution, [{Row, [], [{const, setelement(6, Row, claimed)}]}])),
    ?assertEqual([], mailbox_payloads(whereis(py_distribution)))
end).

closed_admission_revokes_only_unsent_test() -> with_server(fun() ->
    Inc = incarnation(), Token = maps:get(<<"token">>, reserve(Inc, <<"unsent-close">>, <<"12">>)),
    ?assertEqual(<<"ok">>, status(local(#{<<"op">> => <<"close_admission">>}))),
    ?assertEqual(<<"unknown_token">>, status(remote((job(<<"submit">>, Inc, Token))#{<<"payload">> => <<"12">>}))),
    ?assertEqual(0, maps:get(<<"count">>, snapshot()))
end).

event_buffer_exposes_overflow_test() -> with_server(fun() ->
    [whereis(py_distribution) ! {nodeup, 'owned@127.0.0.1', []} || _ <- lists:seq(1, 35)],
    S = snapshot(),
    ?assertEqual(32, length(maps:get(<<"events">>, S))),
    ?assertEqual(3, maps:get(<<"events_dropped">>, S))
end).

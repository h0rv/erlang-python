-module(py_actor_state_SUITE).
-export([all/0, groups/0, init_per_group/2, end_per_group/2,
         init_per_suite/1, end_per_suite/1, explicit_versions/1,
         concurrent_writers/1, disk_restart/1, bounds/1, callback_round_trip/1,
         pooled_actor/1, single_owner/1, cancellation/1, fencing/1, holder_death/1]).

all() -> [explicit_versions, concurrent_writers, disk_restart, bounds, pooled_actor,
          single_owner, cancellation, fencing, holder_death,
          {group, worker}, {group, isolated}].

groups() -> [{worker, [], [callback_round_trip]}, {isolated, [], [callback_round_trip]}].

init_per_group(Mode, Config) -> [{mode, Mode} | Config].
end_per_group(_, _) -> ok.

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_python),
    Dir = filename:join(proplists:get_value(priv_dir, Config), "actor-state"),
    ok = py_actor_state:open(list_to_binary(Dir)),
    [{store, Dir} | Config].

end_per_suite(_) ->
    ok = application:stop(erlang_python),
    application:stop(mnesia).

explicit_versions(_) ->
    Token = own(<<"counter">>),
    missing = py_actor_state:read(<<"counter">>),
    {ok, 1} = py_actor_state:write(<<"counter">>, 0, <<"one">>, Token),
    {ok, 1, <<"one">>} = py_actor_state:read(<<"counter">>),
    {error, {version_conflict, 0, 1}} = py_actor_state:write(<<"counter">>, 0, <<"stale">>, Token),
    {ok, 2} = py_actor_state:write(<<"counter">>, 1, <<"two">>, Token),
    {ok, 2, <<"two">>} = py_actor_state:read(<<"counter">>).

concurrent_writers(_) ->
    Token = own(<<"race">>),
    Parent = self(),
    Writers = [spawn_monitor(fun() ->
        receive go -> ok end,
        Parent ! {self(), py_actor_state:write(<<"race">>, 0, <<N>>, Token)}
    end) || N <- lists:seq(1, 16)],
    [Pid ! go || {Pid, _} <- Writers],
    Results = [receive {Pid, Result} -> Result after 5000 -> error(write_timeout) end
               || {Pid, _} <- Writers],
    1 = length([ok || {ok, 1} <- Results]),
    15 = length([ok || {error, {version_conflict, 0, 1}} <- Results]),
    [receive {'DOWN', Mon, process, Pid, normal} -> ok after 5000 -> error(writer_survived) end
     || {Pid, Mon} <- Writers], ok.

disk_restart(Config) ->
    Token = own(<<"disk">>),
    {ok, 1} = py_actor_state:write(<<"disk">>, 0, <<"saved">>, Token),
    stopped = mnesia:stop(),
    ok = py_actor_state:open(list_to_binary(proplists:get_value(store, Config))),
    {ok, 1, <<"saved">>} = py_actor_state:read(<<"disk">>),
    {error, {store_failed, _, mnesia_directory_mismatch}} = py_actor_state:open(<<"wrong-dir">>).

bounds(_) ->
    {error, invalid_argument} = py_actor_state:claim(<<>>, <<"ref">>),
    {error, invalid_argument} = py_actor_state:claim(<<"key">>, <<>>),
    {error, invalid_argument} = py_actor_state:cancel(<<>>),
    {error, not_owner} = py_actor_state:release(<<>>),
    {error, invalid_argument} = py_actor_state:write(<<>>, 0, <<>>, <<>>),
    {error, invalid_argument} = py_actor_state:write(<<"x">>, -1, <<>>, <<>>),
    {error, invalid_argument} = py_actor_state:write(<<"x">>, 0, binary:copy(<<0>>, 1048577), <<>>),
    {error, invalid_argument} = py_actor_state:read(binary:copy(<<0>>, 4097)),
    missing = py_actor_state:read(<<"x">>).

pooled_actor(Config) ->
    {ok, Context} = py_context:new(#{mode => worker}),
    TestDir = filename:dirname(code:which(?MODULE)),
    try
        ok = py_context:exec(Context, iolist_to_binary(io_lib:format(
            "import sys; sys.path.insert(0, ~p)", [TestDir]))),
        {ok, true} = py_context:call(Context, py_test_worker_pool, persistent_state,
            [list_to_binary(proplists:get_value(store, Config))], #{}, 30000)
    after
        py_context:stop(Context)
    end.

callback_round_trip(Config) ->
    Mode = proplists:get_value(mode, Config),
    {ok, Context} = py_context:new(#{mode => Mode}),
    Dir = proplists:get_value(store, Config),
    Code = iolist_to_binary([
        "import erlang\n",
        "assert erlang.call('_actor_state_open', ", io_lib:format("~p", [Dir]), ") == 'ok'\n",
        "key = b'callback-", atom_to_list(Mode), "'\n",
        "payload = bytes([0, 255, 128, 10])\n",
        "assert erlang.call('_actor_state_read', key) == 'missing'\n",
        "status, token = erlang.call('_actor_state_claim', key, key)\n",
        "assert status == 'ok' and isinstance(token, bytes)\n",
        "assert erlang.call('_actor_state_write', key, 0, payload, token) == ('ok', 1)\n",
        "assert erlang.call('_actor_state_read', key) == ('ok', 1, payload)\n",
        "assert erlang.call('_actor_state_write', key, 0, b'stale', token) == "
        "('error', ('version_conflict', 0, 1))\n",
        "assert erlang.call('_actor_state_release', token) == 'ok'\n",
        "assert erlang.call('_actor_state_cancel', b'cancel-' + key) == 'ok'\n",
        "assert erlang.call('_actor_state_claim', key, b'cancel-' + key) == ('error', 'cancelled')\n"
    ]),
    try
        ok = py_context:exec(Context, Code)
    after
        py_context:stop(Context)
    end.

own(Key) ->
    {ok, Token} = py_actor_state:claim(Key, term_to_binary(make_ref())), Token.

waiting(Key) ->
    Ref = term_to_binary(make_ref()),
    py_actor_state_owner ! {'$gen_call', {self(), Ref}, {claim, Key, Ref}},
    _ = sys:get_state(py_actor_state_owner),
    {Ref, self()}.

single_owner(_) ->
    Key = <<"single">>, Token = own(Key),
    {Ref, _} = waiting(Key),
    receive {Ref, _} -> error(second_owner) after 0 -> ok end,
    ok = py_actor_state:release(Token),
    receive {Ref, {ok, Next}} -> ok = py_actor_state:release(Next)
    after 5000 -> error(claim_not_woken) end.

cancellation(_) ->
    Key = <<"cancel">>, Token = own(Key),
    {Ref, _} = waiting(Key),
    ok = py_actor_state:cancel(Ref),
    receive {Ref, {error, cancelled}} -> ok after 5000 -> error(not_cancelled) end,
    ok = py_actor_state:release(Token),
    WonRef = <<"cancel-after-win">>,
    {ok, Next} = py_actor_state:claim(Key, WonRef),
    ok = py_actor_state:cancel(WonRef),
    {error, not_owner} = py_actor_state:write(Key, 0, <<>>, Next),
    Before = <<"cancel-before-claim">>,
    ok = py_actor_state:cancel(Before),
    {error, cancelled} = py_actor_state:claim(Key, Before),
    Last = own(Key),
    ok = py_actor_state:release(Last).

fencing(_) ->
    Key = <<"fenced">>, Token = own(Key),
    {ok, 1} = py_actor_state:write(Key, 0, <<"one">>, Token),
    ok = py_actor_state:release(Token),
    Next = own(Key),
    {error, not_owner} = py_actor_state:write(Key, 1, <<"stale">>, Token),
    {ok, 2} = py_actor_state:write(Key, 1, <<"two">>, Next),
    ok = py_actor_state:release(Next).

holder_death(_) ->
    Key = <<"holder-death">>, Token = own(Key),
    {Ref, _} = waiting(Key),
    [{py_actor_owner, Key, _, Pid, Token}] = mnesia:dirty_read(py_actor_owner, Key),
    exit(Pid, kill),
    receive {Ref, {ok, Next}} ->
        {error, not_owner} = py_actor_state:write(Key, 0, <<>>, Token),
        ok = py_actor_state:release(Next)
    after 5000 -> error(holder_not_released) end.

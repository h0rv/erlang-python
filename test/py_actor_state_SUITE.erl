-module(py_actor_state_SUITE).
-export([all/0, groups/0, init_per_group/2, end_per_group/2,
         init_per_suite/1, end_per_suite/1, explicit_versions/1,
         concurrent_writers/1, disk_restart/1, bounds/1, callback_round_trip/1]).

all() -> [explicit_versions, concurrent_writers, disk_restart, bounds,
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
    missing = py_actor_state:read(<<"counter">>),
    {ok, 1} = py_actor_state:write(<<"counter">>, 0, <<"one">>),
    {ok, 1, <<"one">>} = py_actor_state:read(<<"counter">>),
    {error, {version_conflict, 0, 1}} = py_actor_state:write(<<"counter">>, 0, <<"stale">>),
    {ok, 2} = py_actor_state:write(<<"counter">>, 1, <<"two">>),
    {ok, 2, <<"two">>} = py_actor_state:read(<<"counter">>).

concurrent_writers(_) ->
    Parent = self(),
    Writers = [spawn_monitor(fun() ->
        receive go -> ok end,
        Parent ! {self(), py_actor_state:write(<<"race">>, 0, <<N>>)}
    end) || N <- lists:seq(1, 16)],
    [Pid ! go || {Pid, _} <- Writers],
    Results = [receive {Pid, Result} -> Result after 5000 -> error(write_timeout) end
               || {Pid, _} <- Writers],
    1 = length([ok || {ok, 1} <- Results]),
    15 = length([ok || {error, {version_conflict, 0, 1}} <- Results]),
    [receive {'DOWN', Mon, process, Pid, normal} -> ok after 5000 -> error(writer_survived) end
     || {Pid, Mon} <- Writers], ok.

disk_restart(Config) ->
    {ok, 1} = py_actor_state:write(<<"disk">>, 0, <<"saved">>),
    stopped = mnesia:stop(),
    ok = py_actor_state:open(list_to_binary(proplists:get_value(store, Config))),
    {ok, 1, <<"saved">>} = py_actor_state:read(<<"disk">>),
    {error, {store_failed, _, mnesia_directory_mismatch}} = py_actor_state:open(<<"wrong-dir">>).

bounds(_) ->
    {error, invalid_argument} = py_actor_state:write(<<>>, 0, <<>>),
    {error, invalid_argument} = py_actor_state:write(<<"x">>, -1, <<>>),
    {error, invalid_argument} = py_actor_state:write(<<"x">>, 0, binary:copy(<<0>>, 1048577)),
    {error, invalid_argument} = py_actor_state:read(binary:copy(<<0>>, 4097)),
    missing = py_actor_state:read(<<"x">>).

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
        "assert erlang.call('_actor_state_write', key, 0, payload) == ('ok', 1)\n",
        "assert erlang.call('_actor_state_read', key) == ('ok', 1, payload)\n",
        "assert erlang.call('_actor_state_write', key, 0, b'stale') == "
        "('error', ('version_conflict', 0, 1))\n"
    ]),
    try
        ok = py_context:exec(Context, Code)
    after
        py_context:stop(Context)
    end.

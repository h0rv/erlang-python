-module(py_distribution).
-behaviour(gen_server).
-export([start/0, request/1, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Only configured node names become atoms. Python sees data, never remote PIDs.
start() ->
    case os:getenv("PYBEAM_DISTRIBUTION") of
        false -> ok;
        Path ->
            {ok, Bytes} = file:read_file(Path),
            Config = json:decode(Bytes),
            {ok, [[Home]]} = init:get_argument(home),
            Home = os:getenv("HOME"),
            Aliases = maps:map(fun(_, Name) -> binary_to_atom(Name, utf8) end,
                              maps:get(<<"nodes">>, Config)),
            {ok, never} = application:get_env(kernel, dist_auto_connect),
            ok = net_kernel:allow(maps:values(Aliases)),
            {ok, _} = gen_server:start({local, ?MODULE}, ?MODULE, [Config, Aliases], []),
            ok = py_callback:register(pybeam_dist_local, fun([Data]) -> local_request(Data) end),
            ok = py_callback:register(pybeam_dist_bind, fun([Inc, Token, Group]) ->
                gen_server:call(?MODULE, {bind, Inc, Token, Group}, 1500)
            end),
            ok = py_callback:register(pybeam_dist_started, fun([Inc, Token, Pid]) ->
                gen_server:call(?MODULE, {started, Inc, Token, Pid}, 1500)
            end),
            ok = py_callback:register(pybeam_dist_remote, fun([Alias, Data])
              when is_binary(Alias), byte_size(Alias) =:= 1,
                   is_binary(Data), byte_size(Data) =< 8192 ->
                case maps:find(Alias, Aliases) of
                    {ok, Node} ->
                        case lists:member(Node, nodes()) of
                            true ->
                                try erpc:call(Node, ?MODULE, request, [Data], 2000)
                                catch _:_ -> encode(#{status => uncertain}) end;
                            false -> encode(#{status => uncertain})
                        end;
                    error -> encode(#{status => unknown_node})
                end;
              (_) -> encode(#{status => oversized})
            end),
            ok
    end.

request(Data) when is_binary(Data), byte_size(Data) =< 8192 ->
    try intake(remote, json:decode(Data))
    catch _:_ -> encode(#{status => uncertain}) end;
request(_) -> encode(#{status => oversized}).

init([Config, Aliases]) ->
    ok = net_kernel:monitor_nodes(true, [nodedown_reason]),
    ?MODULE = ets:new(?MODULE, [named_table, public, set, {write_concurrency, true}]),
    {ok, #{inc => binary:encode_hex(crypto:strong_rand_bytes(16)),
           capacity => maps:get(<<"capacity">>, Config),
           max_bytes => maps:get(<<"max_bytes">>, Config),
           aliases => Aliases, jobs => #{}, ids => #{}, definitions => [],
           events => [], events_dropped => 0, completed => 0}}.

encode(Value) -> iolist_to_binary(json:encode(Value)).
reply(Value, S) -> {reply, encode(Value), S}.
identity(S) -> #{node => atom_to_binary(node()), pid => list_to_binary(pid_to_list(self())),
                 incarnation => maps:get(inc, S)}.
expire(S) ->
    Now = erlang:monotonic_time(millisecond),
    Jobs = maps:filter(fun(T, J) ->
        case {maps:get(phase, J), ets:lookup(?MODULE, T)} of
            {reserved, [Row = {T, _, _, _, Deadline, reserved}]} when Deadline =< Now ->
                %% Expiry and ingress compete on the SAME immutable row.
                ets:select_delete(?MODULE, [{Row, [], [true]}]) =:= 0;
            {reserved, []} -> false;
            _ -> true
        end
    end, maps:get(jobs, S)),
    S#{jobs := Jobs}.

local_request(Data) when is_binary(Data), byte_size(Data) =< 8192 ->
    intake(local, json:decode(Data)).

%% Credits include encoded requests in the local handoff signal/application mailbox.
%% Network decoding and transient RPC caller buffers are not an aggregate RSS budget.
intake(_, #{<<"op">> := <<"submit">>, <<"incarnation">> := Inc,
            <<"token">> := Token, <<"payload">> := Payload}) when is_binary(Payload) ->
    case ets:lookup(?MODULE, Token) of
        [{Token, Inc, Size, Digest, Deadline, reserved} = Row] ->
            case {erlang:monotonic_time(millisecond) < Deadline,
                  byte_size(Payload) =:= Size andalso
                  binary:encode_hex(crypto:hash(sha256, Payload), lowercase) =:= Digest} of
                {false, _} -> encode(#{status => unknown_token});
                {true, false} -> encode(#{status => conflict});
                {true, true} ->
                    Claimed = setelement(6, Row, claimed),
                    case ets:select_replace(?MODULE, [{Row, [], [{const, Claimed}]}]) of
                        1 ->
                            %% If this caller dies before handoff, ownership is UNKNOWN.
                            %% Never undo the claim: a send may already have occurred.
                            gen_server:call(?MODULE, {ingress, Inc, Token, Payload}, 1500);
                        0 -> encode(#{status => invalid_phase})
                    end
            end;
        [{Token, Other, _, _, _, _}] when Other =/= Inc -> encode(#{status => stale});
        [_] -> encode(#{status => invalid_phase});
        [] -> encode(#{status => unknown_token})
    end;
intake(_, #{<<"op">> := <<"submit">>}) -> encode(#{status => conflict});
intake(remote, Request) -> remote_metadata(Request);
intake(local, Request) when is_map(Request) ->
    gen_server:call(?MODULE, {local, maps:remove(<<"payload">>, Request)}, 1500);
intake(_, _) -> encode(#{status => unknown_operation}).

%% A remote control carries only its bounded metadata, never extra application data.
remote_metadata(#{<<"op">> := <<"snapshot">>}) ->
    control(#{<<"op">> => <<"snapshot">>});
remote_metadata(#{<<"op">> := <<"receipt">>, <<"id">> := Id, <<"ack_alias">> := Alias})
  when is_binary(Id), byte_size(Id) =< 64, is_binary(Alias), byte_size(Alias) =:= 1 ->
    control(#{<<"op">> => <<"receipt">>, <<"id">> => Id, <<"ack_alias">> => Alias});
remote_metadata(#{<<"op">> := <<"ack_receipt">>, <<"id">> := Id})
  when is_binary(Id), byte_size(Id) =< 64 ->
    control(#{<<"op">> => <<"ack_receipt">>, <<"id">> => Id});
remote_metadata(#{<<"op">> := <<"reserve">>, <<"incarnation">> := Inc,
                  <<"id">> := Id, <<"definition">> := <<"double">>,
                  <<"size">> := Size, <<"digest">> := Digest} = R)
  when is_binary(Inc), byte_size(Inc) =:= 32, is_binary(Id),
       byte_size(Id) > 0, byte_size(Id) =< 64, is_integer(Size), Size > 0, Size =< 4096,
       is_binary(Digest), byte_size(Digest) =:= 64 ->
    control(maps:with([<<"op">>, <<"incarnation">>, <<"id">>, <<"definition">>,
                       <<"size">>, <<"digest">>], R));
remote_metadata(#{<<"op">> := Op, <<"incarnation">> := Inc, <<"token">> := Token})
  when (Op =:= <<"result">> orelse Op =:= <<"ack">> orelse Op =:= <<"cancel">>),
       is_binary(Inc), byte_size(Inc) =< 32, is_binary(Token), byte_size(Token) =< 32 ->
    control(#{<<"op">> => Op, <<"incarnation">> => Inc, <<"token">> => Token});
remote_metadata(_) -> encode(#{status => unknown_operation}).
control(Request) -> gen_server:call(?MODULE, {remote, Request}, 1500).

handle_call({bind, Inc, Token, Group}, _, S)
  when is_pid(Group), node(Group) =:= node() ->
    case {Inc =:= maps:get(inc, S), maps:find(Token, maps:get(jobs, S)),
          lists:any(fun(J) -> maps:get(group, J, none) =:= Group end,
                    maps:values(maps:get(jobs, S))),
          proc_lib:translate_initial_call(Group)} of
        {true, {ok, #{phase := running} = J}, false, {py_task_group, init, 1}}
          when not is_map_key(group, J) ->
            case group_info(Group) of
                #{jobs := 0, children := [], contexts := [],
                  gate := #{capacity := 1, count := 0, bytes := 0, unsettled := 0, closed := false}} ->
                    reply(#{status => ok}, put_job(Token, J#{group => Group}, S));
                _ -> reply(#{status => uncertain}, S)
            end;
        _ -> reply(#{status => uncertain}, S)
    end;
handle_call({ingress, Inc, Token, Payload}, _, S) ->
    case {Inc =:= maps:get(inc, S), maps:find(Token, maps:get(jobs, S)),
          ets:lookup(?MODULE, Token)} of
        {true, {ok, #{phase := reserved} = J}, [{Token, Inc, _, _, _, claimed}]} ->
            reply(#{status => ok}, put_job(Token, J#{phase := queued, payload => Payload}, S));
        _ -> reply(#{status => uncertain}, S)
    end;
handle_call({started, Inc, Token, Pid}, _From, S)
  when is_pid(Pid), node(Pid) =:= node() ->
    case {Inc =:= maps:get(inc, S), maps:find(Token, maps:get(jobs, S)),
          is_process_alive(Pid), proc_lib:translate_initial_call(Pid)} of
        {true, {ok, #{phase := running, group := Group} = J}, true, {py_task, init, 1}}
          when not is_map_key(worker_pid, J) ->
            %% The request owns a distinct capacity-one native group, bound while empty.
            %% An unrelated local py_task is not completion evidence for this request.
            case group_info(Group) of
                #{jobs := 1, children := [{_, Pid, worker, _}]} ->
                    PidText = list_to_binary(pid_to_list(Pid)),
                    reply(#{status => ok, worker => PidText},
                          put_job(Token, J#{worker => PidText, worker_pid => Pid}, S));
                _ -> reply(#{status => uncertain}, S)
            end;
        _ -> reply(#{status => uncertain}, S)
    end;
handle_call({remote, #{<<"op">> := Op} = Request}, _From, Original)
  when Op =:= <<"snapshot">>; Op =:= <<"receipt">>; Op =:= <<"ack_receipt">>;
       Op =:= <<"reserve">>; Op =:= <<"submit">>; Op =:= <<"result">>;
       Op =:= <<"ack">>; Op =:= <<"cancel">> ->
    dispatch(Request, expire(Original));
handle_call({remote, _}, _From, S) -> reply(#{status => unknown_operation}, S);
handle_call({local, Request}, _From, Original) -> dispatch(Request, expire(Original)).

dispatch(#{<<"op">> := <<"snapshot">>}, S) ->
    Release = erlang:system_info(otp_release),
    {ok, Version} = file:read_file(filename:join([code:root_dir(), "releases", Release, "OTP_VERSION"])),
    reply(#{status => ok, identity => identity(S),
            nodes => [atom_to_binary(N) || N <- nodes()], events => maps:get(events, S),
            events_dropped => maps:get(events_dropped, S),
            count => map_size(maps:get(jobs, S)), completed => maps:get(completed, S),
            capacity => maps:get(capacity, S), max_bytes => maps:get(max_bytes, S),
            definitions => maps:get(definitions, S),
            otp_release => list_to_binary(Release), otp_version => string:trim(Version),
            erts_version => list_to_binary(erlang:system_info(version)), private_home => true}, S);
dispatch(#{<<"op">> := <<"connect">>, <<"alias">> := Alias}, S) ->
    case maps:find(Alias, maps:get(aliases, S)) of
        {ok, N} ->
            true = erlang:monitor_node(N, true),
            reply(#{status => case net_kernel:connect_node(N) of true -> ok; _ -> uncertain end}, S);
        error -> reply(#{status => unknown_node}, S)
    end;
dispatch(#{<<"op">> := <<"disconnect">>, <<"alias">> := Alias}, S) ->
    case maps:find(Alias, maps:get(aliases, S)) of
        {ok, N} -> erlang:disconnect_node(N), reply(#{status => ok}, S);
        error -> reply(#{status => unknown_node}, S)
    end;
dispatch(#{<<"op">> := <<"receipt">>, <<"id">> := Id, <<"ack_alias">> := Alias}, S)
  when is_binary(Id), byte_size(Id) =< 64 ->
    %% The reverse call is initiated in B, not relayed through the Python host.
    case maps:find(Alias, maps:get(aliases, S)) of
        {ok, N} ->
            Ack = try erpc:call(N, ?MODULE, request,
                [encode(#{op => ack_receipt, id => Id})], 1000)
                catch _:_ -> encode(#{status => uncertain}) end,
            AckData = json:decode(Ack),
            case maps:get(<<"status">>, AckData) of
                <<"ok">> -> reply(#{status => ok, receipt => (identity(S))#{message_id => Id},
                                    reverse_ack => AckData}, S);
                _ -> reply(#{status => uncertain}, S)
            end;
        error -> reply(#{status => unknown_node}, S)
    end;
dispatch(#{<<"op">> := <<"ack_receipt">>, <<"id">> := Id}, S)
  when is_binary(Id), byte_size(Id) =< 64 ->
    reply(#{status => ok, receipt => (identity(S))#{message_id => Id}}, S);
dispatch(#{<<"op">> := <<"register">>, <<"definition">> := <<"double">>}, S) ->
    reply(#{status => ok}, S#{definitions := [<<"double">>]});
dispatch(#{<<"op">> := <<"close_admission">>}, S) ->
    %% Claims already won remain charged; only unclaimed rights can be revoked.
    ets:select_delete(?MODULE, [{{'_', '_', '_', '_', '_', reserved}, [], [true]}]),
    reply(#{status => ok}, expire(S#{definitions := []}));
dispatch(#{<<"op">> := <<"reserve">>, <<"incarnation">> := Inc,
           <<"id">> := Id, <<"definition">> := <<"double">>, <<"size">> := Size,
           <<"digest">> := Digest}, S)
  when is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< 64,
       is_binary(Digest), byte_size(Digest) =:= 64,
       is_integer(Size), Size > 0, Size =< 4096 ->
    Jobs = maps:get(jobs, S), Ids = maps:get(ids, S),
    Bytes = lists:sum([maps:get(size, J) || J <- maps:values(Jobs)]),
    case {maps:get(definitions, S) =/= [], Inc =:= maps:get(inc, S), maps:find(Id, Ids),
          map_size(Jobs) < maps:get(capacity, S),
          Bytes + Size =< maps:get(max_bytes, S), map_size(Ids) < 64} of
        {false, _, _, _, _, _} -> reply(#{status => admission_closed}, S);
        {true, false, _, _, _, _} -> reply(#{status => stale}, S);
        {true, true, {ok, Digest}, _, _, _} -> reply(#{status => duplicate}, S);
        {true, true, {ok, _}, _, _, _} -> reply(#{status => conflict}, S);
        {true, true, error, true, true, true} ->
            Token = binary:encode_hex(crypto:strong_rand_bytes(16)),
            J = #{id => Id, size => Size, digest => Digest, phase => reserved,
                  cancel => false, deadline => erlang:monotonic_time(millisecond) + 1000},
            true = ets:insert_new(?MODULE, {Token, Inc, Size, Digest,
                                           maps:get(deadline, J), reserved}),
            reply(#{status => ok, token => Token},
                  S#{jobs := Jobs#{Token => J}, ids := Ids#{Id => Digest}});
        _ -> reply(#{status => overloaded}, S)
    end;
dispatch(#{<<"op">> := Op, <<"incarnation">> := Inc, <<"token">> := Token} = R, S) ->
    case {Inc =:= maps:get(inc, S), maps:find(Token, maps:get(jobs, S))} of
        {false, _} -> reply(#{status => stale}, S);
        {true, error} -> reply(#{status => unknown_token}, S);
        {true, {ok, J}} -> job(Op, Token, J, R, S)
    end;
dispatch(#{<<"op">> := <<"next">>}, S) ->
    case [{T, J} || {T, #{phase := queued} = J} <- maps:to_list(maps:get(jobs, S))] of
        [] -> reply(#{status => empty}, S);
        [{T, J} | _] ->
            reply(#{status => ok, token => T, payload => maps:get(payload, J)},
                  put_job(T, J#{phase := running}, S))
    end;
dispatch(_, S) -> reply(#{status => unknown_operation}, S).

put_job(Token, Job, S) -> S#{jobs := (maps:get(jobs, S))#{Token => Job}}.
job(<<"result">>, _T, #{phase := done, result := R, id := Id, size := Size} = J, _, S) ->
    Proof = case maps:find(worker, J) of
        {ok, Pid} -> #{worker => Pid, worker_dead => true, worker_kind => temporary_otp_task};
        error -> #{}
    end,
    reply(maps:merge(#{status => ok, result => R, job_id => Id, request_bytes => Size,
                      payload => maps:get(payload, J), identity => identity(S)}, Proof), S);
job(<<"result">>, _, #{phase := running, worker := Pid}, _, S) ->
    reply(#{status => pending, worker => Pid, worker_kind => temporary_otp_task}, S);
job(<<"result">>, T, #{phase := reserved}, _, S) ->
    case ets:lookup(?MODULE, T) of
        [{T, _, _, _, _, claimed}] -> reply(#{status => uncertain}, S);
        _ -> reply(#{status => pending}, S)
    end;
job(<<"result">>, _, _, _, S) -> reply(#{status => pending}, S);
job(<<"ack">>, T, #{phase := done}, _, S) ->
    true = ets:delete(?MODULE, T),
    reply(#{status => ok}, S#{jobs := maps:remove(T, maps:get(jobs, S))});
job(<<"cancel">>, T, J, _, S) -> reply(#{status => pending}, put_job(T, J#{cancel := true}, S));
job(<<"cancelled">>, _, J, _, S) -> reply(#{status => ok, cancel => maps:get(cancel, J)}, S);
job(<<"reject">>, T, #{phase := running} = J, _, S) when not is_map_key(worker_pid, J) ->
    reply(#{status => ok}, put_job(T, J#{phase := done, result => <<"{\"error\":\"invalid_request\"}">>}, S));
job(<<"complete">>, T, #{phase := running, worker_pid := Pid} = J,
    #{<<"result">> := R}, S)
  when is_binary(R), byte_size(R) =< 4096 ->
    case is_process_alive(Pid) of
        false -> reply(#{status => ok}, put_job(T, J#{phase := done, result => R},
                                 S#{completed := maps:get(completed, S) + 1}));
        true -> reply(#{status => uncertain}, S)
    end;
job(_, _, _, _, S) -> reply(#{status => invalid_phase}, S).

group_info(Group) ->
    try gen_server:call(Group, info, 500)
    catch exit:_ -> uncertain end.

handle_cast(_, S) -> {noreply, S}.
handle_info({Kind, N, _}, S) when Kind =:= nodeup; Kind =:= nodedown ->
    Event = #{event => Kind, node => atom_to_binary(N)},
    History = maps:get(events, S) ++ [Event],
    Dropped = max(0, length(History) - 32),
    {noreply, S#{events := lists:nthtail(Dropped, History),
                 events_dropped := maps:get(events_dropped, S) + Dropped}};
handle_info({Kind, N}, S) when Kind =:= nodeup; Kind =:= nodedown ->
    handle_info({Kind, N, []}, S);
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

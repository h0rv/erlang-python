-module(py_durable_queue_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2,
         lifecycle/1, dedup/1, limits/1, stale/1, release/1, waiter/1,
         expiry_waiter/1, empty/1, directory/1, crash/1, boot/0,
         sync_failure/1, majority_rejected/1, timed_waiters/1]).

all() -> [lifecycle,dedup,limits,stale,release,waiter,expiry_waiter,empty,directory,
          sync_failure,majority_rejected,timed_waiters,crash].
boot() ->
    {ok,_}=application:ensure_all_started(crypto),
    {ok,Sync}=py_durable_queue_sync:start_link(), unlink(Sync),
    {ok,Queue}=py_durable_queue:start_link(), unlink(Queue), ok.
init_per_suite(Config) -> boot(), Config.
end_per_suite(_) ->
    gen_server:stop(py_durable_queue), gen_server:stop(py_durable_queue_sync), mnesia:stop(), ok.
init_per_testcase(Test, Config) ->
    Dir=unicode:characters_to_binary(filename:join(proplists:get_value(priv_dir,Config),"store")),
    Q=atom_to_binary(Test), ok=py_durable_queue:open(Dir,Q,2), [{queue,Q},{dir,Dir}|Config].
lifecycle(C) ->
    Q=proplists:get_value(queue,C),
    {ok,stored}=py_durable_queue:put(Q,undefined,<<"first">>),
    {ok,stored}=py_durable_queue:put(Q,undefined,<<"second">>),
    {ok,Id,T,1,<<"first">>}=py_durable_queue:claim(Q,1000,0),
    ok=py_durable_queue:ack(Id,T),
    {ok,Id2,T2,1,<<"second">>}=py_durable_queue:claim(Q,1000,0),
    ok=py_durable_queue:ack(Id2,T2), empty=py_durable_queue:claim(Q,1000,0).
dedup(C) ->
    Q=proplists:get_value(queue,C),
    {ok,stored}=py_durable_queue:put(Q,<<"key">>,<<"v">>),
    {ok,duplicate}=py_durable_queue:put(Q,<<"key">>,<<"other">>),
    {ok,Id,T,1,<<"v">>}=py_durable_queue:claim(Q,1000,0),
    {ok,duplicate}=py_durable_queue:put(Q,<<"key">>,<<>>),
    ok=py_durable_queue:ack(Id,T), {ok,stored}=py_durable_queue:put(Q,<<"key">>,<<>>).
limits(C) ->
    Q=proplists:get_value(queue,C),
    {error,payload_too_large}=py_durable_queue:put(Q,undefined,binary:copy(<<0>>,1048577)),
    {ok,stored}=py_durable_queue:put(Q,undefined,<<>>),
    {ok,stored}=py_durable_queue:put(Q,undefined,<<>>),
    {error,full}=py_durable_queue:put(Q,undefined,<<>>).
stale(C) ->
    Q=proplists:get_value(queue,C), {ok,stored}=py_durable_queue:put(Q,undefined,<<>>),
    {ok,Id,T,1,<<>>}=py_durable_queue:claim(Q,20,0), timer:sleep(30),
    {error,stale_lease}=py_durable_queue:ack(Id,T),
    {ok,Id,T2,2,<<>>}=py_durable_queue:claim(Q,1000,0),
    {error,stale_lease}=py_durable_queue:ack(Id,T), ok=py_durable_queue:ack(Id,T2).
release(C) ->
    Q=proplists:get_value(queue,C), {ok,stored}=py_durable_queue:put(Q,undefined,<<>>),
    {ok,Id,T,1,<<>>}=py_durable_queue:claim(Q,1000,0), ok=py_durable_queue:release(Id,T),
    {ok,Id,T2,2,<<>>}=py_durable_queue:claim(Q,1000,0), ok=py_durable_queue:ack(Id,T2).
waiter(C) ->
    Q=proplists:get_value(queue,C), Parent=self(),
    spawn(fun()->Parent!{claim,py_durable_queue:claim(Q,1000,1000)}end),
    receive {claim,_}->error(did_not_block) after 30->ok end,
    {ok,stored}=py_durable_queue:put(Q,undefined,<<"wake">>),
    receive {claim,{ok,Id,T,1,<<"wake">>}} -> ok=py_durable_queue:ack(Id,T)
    after 2000 -> error(waiter_not_woken) end.
expiry_waiter(C) ->
    Q=proplists:get_value(queue,C), {ok,stored}=py_durable_queue:put(Q,undefined,<<>>),
    {ok,Id,_,1,<<>>}=py_durable_queue:claim(Q,40,0),
    {ok,Id,T,2,<<>>}=py_durable_queue:claim(Q,1000,1000), ok=py_durable_queue:ack(Id,T).
empty(C) -> empty=py_durable_queue:claim(proplists:get_value(queue,C),1000,10).
directory(C) ->
    {error,_}=py_durable_queue:open(<<"/not-the-open-store">>,proplists:get_value(queue,C),2).
sync_failure(_) ->
    stopped=mnesia:stop(),
    try
        ok=gen_server:call(py_durable_queue_sync,{enqueue,{self(),result},ok}),
        receive {result,{error,{sync_failed,_}}}->ok after 2000->error(missing_sync_error) end
    after ok=mnesia:start(), ok=mnesia:wait_for_tables([dq_item,dq_meta],30000) end.
majority_rejected(C) ->
    {atomic,ok}=mnesia:change_table_majority(dq_item,true),
    try {error,_}=py_durable_queue:put(proplists:get_value(queue,C),undefined,<<>>)
    after {atomic,ok}=mnesia:change_table_majority(dq_item,false) end.
timed_waiters(C) ->
    Q=proplists:get_value(queue,C), Parent=self(),
    spawn(fun()->Parent!{long,py_durable_queue:claim(Q,1000,1000)}end), timer:sleep(10),
    empty=py_durable_queue:claim(Q,1000,10),
    {ok,stored}=py_durable_queue:put(Q,undefined,<<>>),
    receive {long,{ok,Id,T,1,<<>>}}->ok=py_durable_queue:ack(Id,T)
    after 2000->error(waiter_timeout) end.

crash(C) ->
    Dir=unicode:characters_to_binary(filename:join(proplists:get_value(priv_dir,C),"crash")),
    {P,N}=peer_node(),
    try
        ok=peer:call(P,?MODULE,boot,[]),
        ok=peer:call(P,py_durable_queue,open,[Dir,<<"q">>,2]),
        {ok,stored}=peer:call(P,py_durable_queue,put,[<<"q">>,<<"keep">>,<<"data">>]),
        kill_peer(P),
        {P2,N}=peer_node(),
        try
            ok=peer:call(P2,?MODULE,boot,[]),
            ok=peer:call(P2,py_durable_queue,open,[Dir,<<"q">>,2]),
            {ok,Id,T,1,<<"data">>}=peer:call(P2,py_durable_queue,claim,[<<"q">>,10000,0]),
            ok=peer:call(P2,py_durable_queue,ack,[Id,T]), kill_peer(P2),
            {P3,N}=peer_node(),
            try
                ok=peer:call(P3,?MODULE,boot,[]),
                ok=peer:call(P3,py_durable_queue,open,[Dir,<<"q">>,2]),
                empty=peer:call(P3,py_durable_queue,claim,[<<"q">>,1000,0]),
                {ok,stored}=peer:call(P3,py_durable_queue,put,[<<"q">>,<<"keep">>,<<"new">>])
            after stop_peer(P3) end
        after stop_peer(P2) end
    after stop_peer(P) end.
stop_peer(P) -> try peer:stop(P) catch exit:_ -> ok end.
peer_node() ->
    Paths=lists:append([["-pa",filename:absname(P)] || P <- code:get_path()]),
    {ok,P,N}=peer:start(#{name=>dq_crash,connection=>standard_io,
        args=>["+S","2:2","+A","2"|Paths]}), {P,N}.
kill_peer(P) ->
    Pid=peer:call(P,os,getpid,[]), Mon=monitor(process,P),
    os:cmd("kill -9 "++Pid),
    receive {'DOWN',Mon,process,P,_}->ok after 10000->error(kill_timeout) end.

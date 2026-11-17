-module(py_loop_owner_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0,init_per_suite/1,end_per_suite/1,guard_shared/1,guard_dedicated/1,
         release_and_initialization/1,concurrent_claims/1,foreign_interpreter/1,
         owner_exit_during_processing/1,completed_sync_during_processing/1,
         completed_coroutine_during_processing/1,completed_empty_during_processing/1,
         completed_error_during_processing/1]).

all() -> [guard_shared,guard_dedicated,release_and_initialization,concurrent_claims,
          foreign_interpreter,owner_exit_during_processing,completed_sync_during_processing,
          completed_coroutine_during_processing,completed_empty_during_processing,
          completed_error_during_processing].
init_per_suite(Config) ->
    {ok,_}=application:ensure_all_started(erlang_python),
    ok=py_callback:register(<<"owner_echo">>,fun([Value])->Value end),
    [{test_dir,filename:dirname(code:which(?MODULE))}|Config].
end_per_suite(_) -> application:stop(erlang_python).

guard_shared(Config) -> guard(Config,shared).
guard_dedicated(Config) -> guard(Config,dedicated).
guard(Config,Kind) ->
    A=context(Config,#{mode=>worker,managed_loop=>Kind}),
    B=context(Config,#{mode=>worker}),
    ok=py_context:start_loop(A),
    {ok,<<"waiting">>}=py_context:submit_await(A,py_test_loop_owner,setup,[],#{},5000),
    {ok,Loop}=py_context:loop_ref(A),
    {error,loop_running}=py_nif:event_loop_release_python_loop(Loop),
    {ok,<<"exclusive-owner-preserved">>}=py_context:call(B,py_test_loop_owner,reject_active,[Loop,Kind=:=shared]),
    {ok,<<"callbacks-complete">>}=py_context:submit_await(A,py_test_loop_owner,finish,[],#{},5000),
    stop_loop(A), ok=py_context:stop(A), ok=py_context:stop(B).

release_and_initialization(Config) ->
    B=context(Config,#{mode=>worker}),
    {ok,Loop}=py_nif:event_loop_new(),
    {ok,<<"exact-release-and-rebind">>}=py_context:call(B,py_test_loop_owner,initial_and_closed,[Loop]),
    {ok,<<"initialization-error-unclaimed">>}=py_context:call(B,py_test_loop_owner,initialization_error,[Loop]),
    {ok,<<"disposed-resource-cannot-rebind">>}=py_context:call(B,py_test_loop_owner,disposal,[Loop]),
    ok=py_nif:event_loop_destroy(Loop), ok=py_context:stop(B).

concurrent_claims(Config) ->
    B=context(Config,#{mode=>worker}),
    C=context(Config,#{mode=>worker}),
    {ok,Loop}=py_nif:event_loop_new(),
    {ok,<<"prepared">>}=py_context:call(B,py_test_loop_owner,prepare_concurrent,[]),
    Parent=self(),
    [spawn(fun()->Parent!{claim_result,py_context:call(Context,py_test_loop_owner,contend,[Loop])} end)
        || Context<-[B,C]],
    Results=[receive {claim_result,Result}->Result after 7000->ct:fail(claim_timeout) end || _<-[1,2]],
    [{ok,<<"claimed">>},{ok,<<"rejected">>}]=lists:sort(Results),
    {ok,<<"one-claim-released">>}=py_context:call(B,py_test_loop_owner,finish_concurrent,[Loop]),
    ok=py_nif:event_loop_destroy(Loop), ok=py_context:stop(B), ok=py_context:stop(C).

foreign_interpreter(Config) ->
    A=context(Config,#{mode=>worker,managed_loop=>dedicated}),
    S=context(Config,#{mode=>owngil}),
    ok=py_context:start_loop(A),
    {ok,Loop}=py_context:loop_ref(A),
    {error,arg_conversion_failed}=py_context:call(S,py_test_loop_owner,reject_active,[Loop,false]),
    stop_loop(A), ok=py_context:stop(A), ok=py_context:stop(S).

owner_exit_during_processing(Config) ->
    {error,loop_stopped}=retiring_call(Config,retiring_factory).

completed_sync_during_processing(Config) ->
    {ok,<<"completed">>}=retiring_call(Config,retiring_result).

completed_coroutine_during_processing(Config) ->
    B=context(Config,#{mode=>worker}),
    {ok,Loop}=py_nif:event_loop_new(),
    ok=py_callback:register(<<"owner_destroy_loop">>,fun([])->
        py_nif:event_loop_destroy(Loop)
    end),
    try
        Ref=make_ref(),
        ok=py_nif:submit_task(Loop,self(),Ref,<<"py_test_loop_teardown">>,
                              <<"retiring_completed">>,[],#{}),
        {error,loop_stopped}=py_nif:process_ready_tasks(Loop),
        {ok,<<"completed">>}=py_event_loop:await(Ref,2000)
    after
        py_callback:unregister(<<"owner_destroy_loop">>),
        py_nif:event_loop_release_python_loop(Loop),
        py_nif:event_loop_destroy(Loop),
        py_context:stop(B)
    end.

completed_empty_during_processing(Config) ->
    {ok,<<>>}=retiring_call(Config,retiring_empty).

completed_error_during_processing(Config) ->
    {error,{'ValueError',"completed failure"}}=retiring_call(Config,retiring_error).

retiring_call(Config,Function) ->
    A=context(Config,#{mode=>worker,managed_loop=>dedicated}),
    B=context(Config,#{mode=>worker}),
    {Owner,Mon}=spawn_monitor(fun()->
        ok=py_context:start_loop(A),
        {ok,<<"armed">>}=py_context:submit_await(A,py_test_loop_teardown,arm,[],#{},5000)
    end),
    try
        receive {'DOWN',Mon,process,Owner,normal}->ok
        after 7000->ct:fail(owner_did_not_exit) end,
        {ok,<<"closing">>}=py_context:call(B,py_test_loop_teardown,wait_closing,[]),
        {ok,Ref}=py_context:submit(A,py_test_loop_teardown,Function,[],#{}),
        Outcome=py_event_loop:await(Ref,2000),
        {ok,<<"no-system-error">>}=py_context:call(B,py_test_loop_teardown,finish,[]),
        Outcome
    after
        py_context:call(B,py_test_loop_teardown,finish,[]),
        py_context:stop(A), py_context:stop(B)
    end.

context(Config,Opts) ->
    {ok,C}=py_context:new(Opts),
    Code=iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, ~p); import py_test_loop_owner",[?config(test_dir,Config)])),
    ok=py_context:exec(C,Code), C.
stop_loop(C) ->
    ok=py_context:stop_loop(C,1000),
    receive {py_loop_exit,C,{ok,<<"stopped">>}} -> ok
    after 2000 -> ct:fail(no_clean_ack) end.

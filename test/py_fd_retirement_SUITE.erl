-module(py_fd_retirement_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1, retired_for_test/1,
         paused_reader/1, delivered_reader/1, paused_writer/1, delivered_writer/1,
         never_selected/1, owner_down/1, reactor_close/1, reactor_owner_down/1,
         close_reselect_race/1]).

all() -> [paused_reader, delivered_reader, paused_writer, delivered_writer,
          never_selected, owner_down, reactor_close, reactor_owner_down,
          close_reselect_race].
init_per_suite(Config) ->
    application:load(erlang_python),
    application:set_env(erlang_python, num_contexts, 1),
    application:set_env(erlang_python, event_loop_pool_size, 1),
    {ok, _} = application:ensure_all_started(erlang_python), Config.
end_per_suite(_) -> application:stop(erlang_python).

loop() ->
    {ok, L} = py_nif:event_loop_new(),
    ok = py_nif:event_loop_set_worker(L, self()), L.

retired_for_test(R) -> retired(R).
retired(R) -> retired(R, erlang:monotonic_time(millisecond) + 2000).
retired(R, Deadline) ->
    case py_nif:fd_lifecycle_info(R) of
        {2, 3, -1, 1, Direct, Result} = Info when Direct =< 1, Result >= 0 ->
            io:format("ACTUAL_STOP ~p~n", [Info]), ok;
        Info ->
            true = erlang:monotonic_time(millisecond) < Deadline,
            erlang:yield(),
            case Info of {1, 2, _, _, _, _} -> ok; _ -> error({not_retiring, Info}) end,
            retired(R, Deadline)
    end.

replacement(OldFd, Old, OldLoop) ->
    {ok, {Fd, Peer}} = py_nif:socketpair(),
    OldFd = Fd,
    NewLoop = loop(),
    {ok, New} = py_nif:add_reader(NewLoop, Fd, 300),
    ok = py_nif:close_fd(Old),
    {ok, 3} = py_nif:fd_write(Peer, <<"new">>),
    receive {select, New, _, ready_input} -> ok after 1000 -> error(no_new_owner) end,
    {ok, <<"new">>} = py_nif:fd_read(Fd, 3),
    ok = py_nif:handle_fd_event(New, read),
    [{300, read}] = py_nif:get_pending(NewLoop),
    [] = py_nif:get_pending(OldLoop),
    ok = py_nif:close_fd(New), retired(New),
    ok = py_nif:fd_close(Peer),
    ok = py_nif:event_loop_destroy(NewLoop).

exercise(Type, Delivered) ->
    L = loop(), {ok, {Fd, Peer}} = py_nif:socketpair(),
    {ok, R} = case Type of
        read -> py_nif:add_reader(L, Fd, 100);
        write -> py_nif:add_writer(L, Fd, 100)
    end,
    case {Type, Delivered} of
        {read, true} -> {ok, 3} = py_nif:fd_write(Peer, <<"old">>);
        _ -> ok
    end,
    case Delivered of
        true -> receive {select, R, _, _} -> ok after 1000 -> error(no_delivery) end;
        false -> ok
    end,
    ok = case Type of read -> py_nif:stop_reader(R); write -> py_nif:stop_writer(R) end,
    {0, 1, Fd, 0, 0, 0} = py_nif:fd_lifecycle_info(R),
    ok = py_nif:close_fd(R), retired(R),
    ok = py_nif:close_fd(R),
    replacement(Fd, R, L),
    ok = py_nif:fd_close(Peer), ok = py_nif:event_loop_destroy(L).

paused_reader(_) -> exercise(read, false).
delivered_reader(_) -> exercise(read, true).
paused_writer(_) -> exercise(write, false).
delivered_writer(_) -> exercise(write, true).

never_selected(_) ->
    {ok, {Fd, Peer}} = py_nif:socketpair(),
    {ok, R} = py_nif:create_test_fd_resource(Fd),
    {0, 0, Fd, 0, 0, 0} = py_nif:fd_lifecycle_info(R),
    ok = py_nif:close_fd(R),
    {2, 0, -1, 0, 0, 0} = py_nif:fd_lifecycle_info(R),
    L = loop(), replacement(Fd, R, L),
    ok = py_nif:fd_close(Peer), ok = py_nif:event_loop_destroy(L).

owner_down(_) -> owner_case(raw).
reactor_owner_down(_) -> owner_case(reactor).
owner_case(Mode) ->
    Parent = self(),
    {ok, C, _} = py_nif:context_create(worker),
    {P, M} = spawn_monitor(fun() ->
        L = loop(), {ok, {Fd, Peer}} = py_nif:socketpair(),
        {ok, R} = case Mode of
            raw -> py_nif:add_reader(L, Fd, 100);
            reactor -> py_nif:reactor_register_fd(C, Fd, self())
        end,
        ok = py_nif:stop_reader(R),
        Parent ! {owned, self(), L, Fd, Peer, R},
        receive finish -> ok end
    end),
    receive {owned, P, L, Fd, Peer, R} ->
        P ! finish,
        receive {'DOWN', M, process, P, normal} -> ok after 1000 -> error(owner_alive) end,
        retired(R), replacement(Fd, R, L),
        ok = py_nif:fd_close(Peer), ok = py_nif:event_loop_destroy(L)
    after 2000 -> error(owner_not_ready) end,
    ok = py_nif:context_destroy(C).

reactor_close(_) ->
    {ok, C, _} = py_nif:context_create(worker),
    {ok, {Fd, Peer}} = py_nif:socketpair(),
    {ok, R} = py_nif:reactor_register_fd(C, Fd, self()),
    ok = py_nif:stop_reader(R),
    ok = py_nif:reactor_close_fd(C, R), retired(R),
    ok = py_nif:reactor_close_fd(C, R),
    {error, fd_closing} = py_nif:reactor_reselect_read(R),
    L = loop(), replacement(Fd, R, L),
    ok = py_nif:fd_close(Peer), ok = py_nif:event_loop_destroy(L),
    ok = py_nif:context_destroy(C).

close_reselect_race(_) ->
    lists:foreach(fun(_) ->
        L = loop(), {ok, {Fd, Peer}} = py_nif:socketpair(),
        {ok, R} = py_nif:add_reader(L, Fd, 100),
        Parent = self(), Barrier = make_ref(),
        Workers = [spawn_monitor(fun() ->
            Parent ! {ready, self()},
            receive {go, Barrier} -> ok end,
            Reply = case Operation of
                close -> py_nif:close_fd(R);
                reselect -> py_nif:start_reader(R)
            end,
            Parent ! {result, self(), Reply}
        end) || Operation <- [close, close, reselect]],
        [receive {ready, P} -> ok after 1000 -> error(no_barrier) end || {P, _} <- Workers],
        [P ! {go, Barrier} || {P, _} <- Workers],
        [receive {result, P, Reply} ->
             case Reply of
                 ok -> ok;
                 {error, fd_closing} -> ok;
                 {error, select_failed} -> ok;
                 {error, retirement_pending} -> ok
             end
         after 1000 -> error(no_result) end || {P, _} <- Workers],
        [receive {'DOWN', M, process, P, normal} -> ok after 1000 -> error(worker_alive) end
         || {P, M} <- Workers],
        retired(R), replacement(Fd, R, L),
        ok = py_nif:fd_close(Peer), ok = py_nif:event_loop_destroy(L)
    end, lists:seq(1, 8)).

-module(py_supervision).
-behaviour(supervisor).

-export([start_link/1, init/1, register_callbacks/0, callback/1]).

%% Install this supervisor as a child of the application's OTP supervisor.
%% There is deliberately no unowned root creation callback.
-spec start_link(map()) -> supervisor:startlink_ret().
start_link(#{mailbox := unbounded, max_children := unbounded} = Flags) ->
    supervisor:start_link(?MODULE, maps:without([mailbox, max_children], Flags));
start_link(_) ->
    {error, {capability_unavailable, supervision_admission}}.

init(#{strategy := Strategy, intensity := Intensity, period := Period} = Flags)
  when (Strategy =:= one_for_one orelse Strategy =:= one_for_all orelse
        Strategy =:= rest_for_one),
       is_integer(Intensity), Intensity >= 0,
       is_integer(Period), Period > 0 ->
    {ok, {Flags, []}}.

register_callbacks() ->
    py_callback:register('_supervision', {?MODULE, callback}).

%% All values use the existing native term conversion. Never create atoms
%% from application input. MFA modules must already be loaded by the owner.
callback([<<"unbounded">>, <<"unbounded">>, <<"unbounded">> | Args]) ->
    unbounded_callback(Args);
callback(_) ->
    erlang:error({capability_unavailable, supervision_admission}).

unbounded_callback([<<"start_supervisor">>, Sup, Id, Strategy, Intensity, Period,
                    <<"unbounded">>, <<"unbounded">>, <<"unbounded">>])
  when is_pid(Sup), is_binary(Id) ->
    Flags = #{strategy => strategy(Strategy), intensity => Intensity, period => Period,
              mailbox => unbounded, max_children => unbounded},
    Spec = #{id => Id, start => {?MODULE, start_link, [Flags]},
             restart => permanent, shutdown => infinity, type => supervisor},
    result(supervisor:start_child(Sup, Spec));
unbounded_callback([<<"start">>, Sup, Id, Module, Function, Args, Restart, Shutdown,
                    <<"unbounded">>, <<"unbounded">>])
  when is_pid(Sup), is_binary(Id), is_binary(Module), is_binary(Function),
       is_list(Args), is_integer(Shutdown), Shutdown >= 0,
       Shutdown =< 4294967295 ->
    Spec = #{id => Id,
             start => {binary_to_existing_atom(Module, utf8),
                       binary_to_existing_atom(Function, utf8), Args},
             restart => restart(Restart), shutdown => Shutdown,
             type => worker},
    result(supervisor:start_child(Sup, Spec));
unbounded_callback([<<"children">>, Sup]) when is_pid(Sup) ->
    [{{bytes, Id}, process(Pid), status(Pid), atom_to_binary(Type)} ||
        {Id, Pid, Type, _} <- supervisor:which_children(Sup)];
unbounded_callback([<<"stop">>, Sup, Id]) when is_pid(Sup), is_binary(Id) ->
    result(supervisor:terminate_child(Sup, Id));
unbounded_callback([<<"restart">>, Sup, Id]) when is_pid(Sup), is_binary(Id) ->
    result(supervisor:restart_child(Sup, Id));
unbounded_callback([<<"delete">>, Sup, Id]) when is_pid(Sup), is_binary(Id) ->
    result(supervisor:delete_child(Sup, Id));
unbounded_callback(_) ->
    erlang:error({capability_unavailable, supervision_admission}).

strategy(<<"one_for_one">>) -> one_for_one;
strategy(<<"one_for_all">>) -> one_for_all;
strategy(<<"rest_for_one">>) -> rest_for_one.

restart(<<"permanent">>) -> permanent;
restart(<<"transient">>) -> transient;
restart(<<"temporary">>) -> temporary.

process(Pid) when is_pid(Pid) -> Pid;
process(_) -> undefined.

status(Pid) when is_pid(Pid) -> <<"running">>;
status(restarting) -> <<"restarting">>;
status(undefined) -> <<"stopped">>.

result(ok) -> {<<"ok">>, undefined};
result({ok, Pid}) -> {<<"ok">>, Pid};
result({ok, Pid, _Info}) -> {<<"ok">>, Pid};
result({error, Reason}) -> {<<"error">>, Reason}.

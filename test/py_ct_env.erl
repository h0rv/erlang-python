-module(py_ct_env).
-export([override/2, restore/1]).

override(Config, Env) ->
    _ = application:load(erlang_python),
    Previous = [{Key, application:get_env(erlang_python, Key)} || Key <- maps:keys(Env)],
    maps:foreach(fun(Key, Value) -> ok = application:set_env(erlang_python, Key, Value) end, Env),
    [{previous_erlang_python_env, Previous} | Config].

restore(Config) ->
    lists:foreach(
        fun
            ({Key, undefined}) -> ok = application:unset_env(erlang_python, Key);
            ({Key, {ok, Value}}) -> ok = application:set_env(erlang_python, Key, Value)
        end,
        proplists:get_value(previous_erlang_python_env, Config)
    ).

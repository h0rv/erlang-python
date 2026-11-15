-module(py_application_SUITE).
-export([all/0, standard_application/1, wrong_version/1, wrong_erts/1,
         relative_path/1, invalid_name/1, missing_application/1]).

all() -> [standard_application, wrong_version, wrong_erts, relative_path, invalid_name,
          missing_application].

arguments() ->
    {ok, Version} = application:get_key(stdlib, vsn),
    [[list_to_binary(filename:join(code:lib_dir(stdlib), "ebin"))],
     [{<<"stdlib">>, list_to_binary(Version)}],
     list_to_binary(erlang:system_info(version))].

standard_application(_) ->
    <<"ok">> = py_application:callback(arguments()),
    <<"ok">> = py_application:callback(arguments()),
    ok.

wrong_version(_) ->
    [Paths, _, ERTS] = arguments(),
    rejected(fun() -> py_application:callback([Paths, [{<<"stdlib">>, <<"0.0.0">>}], ERTS]) end).

wrong_erts(_) ->
    [Paths, Apps, _] = arguments(),
    rejected(fun() -> py_application:callback([Paths, Apps, <<"0.0.0">>]) end).

relative_path(_) ->
    [_, Apps, ERTS] = arguments(),
    rejected(fun() -> py_application:callback([[<<"relative/ebin">>], Apps, ERTS]) end).

invalid_name(_) ->
    [Paths, _, ERTS] = arguments(),
    rejected(fun() -> py_application:callback([Paths, [{<<"../stdlib">>, <<"1">>}], ERTS]) end).

missing_application(_) ->
    [Paths, _, ERTS] = arguments(),
    rejected(fun() -> py_application:callback([Paths, [{<<"not_installed">>, <<"1">>}], ERTS]) end).

rejected(Function) ->
    try Function(), error(unexpected_success)
    catch
        error:{badmatch, _} -> ok;
        error:{incompatible_application, _, _, _} -> ok;
        error:{unavailable_application, _} -> ok
    end.

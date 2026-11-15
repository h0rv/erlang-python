-module(py_application_SUITE).
-export([all/0, standard_application/1, wrong_version/1, wrong_erts/1,
         relative_path/1, invalid_name/1, missing_application/1,
         stale_loaded_module/1, matching_loaded_module/1, lazy_module/1, extra_module/1,
         unknown_old_code/1]).

all() -> [standard_application, wrong_version, wrong_erts, relative_path, invalid_name,
          missing_application, stale_loaded_module, matching_loaded_module, lazy_module,
          extra_module, unknown_old_code].

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

stale_loaded_module(_) -> fixture(fun(Directory, Expected) ->
    Module = py_application_fixture,
    Old = binary(old),
    File = filename:join(Directory, "py_application_fixture.beam"),
    {module, Module} = code:load_binary(Module, File, Old),
    File = code:which(Module),
    ActualMD5 = Module:module_info(md5),
    {ok, {Module, ExpectedMD5}} = beam_lib:md5(Expected),
    try py_application:callback(fixture_arguments(Directory)), error(unexpected_success)
    catch error:{incompatible_module, Module, ExpectedMD5, ActualMD5} -> ok end,
    old = Module:marker(),
    ActualMD5 = Module:module_info(md5),
    File = code:which(Module),
    false = lists:member(Directory, code:get_path()),
    undefined = application:get_key(py_application_fixture_app, vsn),
    ok
end).

matching_loaded_module(_) -> fixture(fun(Directory, Expected) ->
    Module = py_application_fixture,
    {module, Module} = code:load_binary(Module, "matching-code-without-a-file.beam", Expected),
    Digest = Module:module_info(md5),
    <<"ok">> = py_application:callback(fixture_arguments(Directory)),
    <<"ok">> = py_application:callback(fixture_arguments(Directory)),
    expected = Module:marker(),
    Digest = Module:module_info(md5),
    "matching-code-without-a-file.beam" = code:which(Module),
    ok
end).

unknown_old_code(_) -> fixture(fun(Directory, Expected) ->
    Module = py_application_fixture,
    {module, Module} = code:load_binary(Module, "older-version.beam", binary(old)),
    {module, Module} = code:load_binary(Module, "matching-version.beam", Expected),
    true = erlang:check_old_code(Module),
    Digest = Module:module_info(md5),
    try py_application:callback(fixture_arguments(Directory)), error(unexpected_success)
    catch error:{incompatible_module, Module, unknown_old_code} -> ok end,
    true = erlang:check_old_code(Module),
    Digest = Module:module_info(md5),
    expected = Module:marker(),
    ok
end).

lazy_module(_) -> fixture(fun(Directory, _) ->
    false = code:is_loaded(py_application_fixture),
    <<"ok">> = py_application:callback(fixture_arguments(Directory)),
    false = code:is_loaded(py_application_fixture),
    {module, py_application_fixture} = code:ensure_loaded(py_application_fixture),
    expected = py_application_fixture:marker(),
    ok
end).

extra_module(_) -> fixture(fun(Directory, Expected) ->
    ok = file:write_file(filename:join(Directory, "erl_eval.beam"), Expected),
    try py_application:callback(fixture_arguments(Directory)), error(unexpected_success)
    catch error:{invalid_application_modules, py_application_fixture_app} -> ok end,
    false = lists:member(Directory, code:get_path()),
    ok
end).

fixture_arguments(Directory) ->
    [[list_to_binary(Directory)], [{<<"py_application_fixture_app">>, <<"1.0.0">>}],
     list_to_binary(erlang:system_info(version))].

fixture(Function) ->
    Directory = filename:join(os:getenv("TMPDIR", "/tmp"),
        "py-application-fixture-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Directory),
    Expected = binary(expected),
    ok = file:write_file(filename:join(Directory, "py_application_fixture.beam"), Expected),
    Spec = {application, py_application_fixture_app,
        [{vsn, "1.0.0"}, {modules, [py_application_fixture]}, {applications, [kernel, stdlib]}]},
    ok = file:write_file(filename:join(Directory, "py_application_fixture_app.app"),
                         io_lib:format("~tp.~n", [Spec])),
    try Function(Directory, Expected)
    after
        application:stop(py_application_fixture_app),
        application:unload(py_application_fixture_app),
        code:purge(py_application_fixture),
        code:delete(py_application_fixture),
        code:purge(py_application_fixture),
        code:del_path(Directory),
        file:del_dir_r(Directory)
    end.

binary(Value) ->
    Forms = [{attribute, 1, module, py_application_fixture},
             {attribute, 1, export, [{marker, 0}]},
             {function, 1, marker, 0, [{clause, 1, [], [], [{atom, 1, Value}]}]}],
    {ok, py_application_fixture, Binary} = compile:forms(Forms, [binary, return_errors]),
    Binary.

rejected(Function) ->
    try Function(), error(unexpected_success)
    catch
        error:{badmatch, _} -> ok;
        error:{incompatible_application, _, _, _} -> ok;
        error:{unavailable_application, _} -> ok
    end.

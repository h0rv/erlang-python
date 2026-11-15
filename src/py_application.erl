-module(py_application).
-export([register_callbacks/0, callback/1]).

register_callbacks() ->
    py_callback:register('_application_start', {?MODULE, callback}).

callback([Paths, Applications, ERTS]) when is_binary(ERTS), is_list(Paths), is_list(Applications),
                                    length(Paths) > 0, length(Paths) =< 16,
                                    length(Applications) > 0, length(Applications) =< 16 ->
    compatible(erts, ERTS, list_to_binary(erlang:system_info(version))),
    Directories = [directory(Path) || Path <- Paths],
    Specs = [spec(Application, Directories) || Application <- Applications],
    lists:foreach(fun preflight/1, Specs),
    ok = code:add_pathsa(Directories),
    lists:foreach(fun({_, _, Spec, _}) ->
        case application:load(Spec) of
            ok -> ok;
            {error, {already_loaded, _}} -> ok
        end
    end, Specs),
    lists:foreach(fun({Name, _, _, _}) ->
        {ok, _} = application:ensure_all_started(Name)
    end, Specs),
    lists:foreach(fun preflight/1, Specs),
    <<"ok">>.

directory(Path) when is_binary(Path) ->
    Directory = unicode:characters_to_list(Path),
    absolute = filename:pathtype(Directory),
    true = filelib:is_dir(Directory),
    Directory.

spec({Name, Expected}, Directories) when is_binary(Name), is_binary(Expected) ->
    match = re:run(Name, <<"^[a-z][a-z0-9_]*$">>, [{capture, none}]),
    FileName = binary_to_list(Name) ++ ".app",
    Matches = [filename:join(Directory, FileName) || Directory <- Directories,
               filelib:is_regular(filename:join(Directory, FileName))],
    File = case Matches of
        [Found] -> Found;
        _ -> error({unavailable_application, Name})
    end,
    {ok, [{application, Atom, Properties} = Spec]} = file:consult(File),
    Name = atom_to_binary(Atom),
    Version = proplists:get_value(vsn, Properties),
    compatible(Atom, Expected, unicode:characters_to_binary(Version)),
    Modules = proplists:get_value(modules, Properties),
    true = is_list(Modules) andalso length(Modules) > 0 andalso length(Modules) =< 1024,
    true = length(Modules) =:= length(lists:usort(Modules)),
    ExpectedFiles = lists:sort([atom_to_list(Module) ++ ".beam" || Module <- Modules]),
    Directory = filename:dirname(File),
    ActualFiles = lists:sort([filename:basename(Path) || Path <-
                             filelib:wildcard(filename:join(Directory, "*.beam"))]),
    case ActualFiles =:= ExpectedFiles of
        true -> ok;
        false -> error({invalid_application_modules, Atom})
    end,
    Identities = [identity(Module, Directory) || Module <- Modules],
    {Atom, Version, Spec, Identities}.

identity(Module, Directory) when is_atom(Module) ->
    File = filename:join(Directory, atom_to_list(Module) ++ ".beam"),
    {ok, Binary} = file:read_file(File),
    {ok, {Module, MD5}} = beam_lib:md5(Binary),
    {Module, MD5}.

preflight({Name, Version, _, Modules}) ->
    case application:get_key(Name, vsn) of
        undefined -> ok;
        {ok, Loaded} -> compatible(Name, list_to_binary(Version), list_to_binary(Loaded))
    end,
    lists:foreach(fun({Module, Expected}) ->
        case erlang:check_old_code(Module) of
            false -> ok;
            true -> error({incompatible_module, Module, unknown_old_code})
        end,
        case code:is_loaded(Module) of
            false -> ok;
            {file, _} ->
                Actual = try Module:module_info(md5) catch _:_ -> unknown end,
                case Actual of
                    Expected -> ok;
                    Digest when is_binary(Digest), byte_size(Digest) =:= 16 ->
                        error({incompatible_module, Module, Expected, Digest});
                    _ -> error({incompatible_module, Module, unknown_identity})
                end
        end
    end, Modules).

compatible(_Application, Version, Version) -> ok;
compatible(Application, Expected, Actual) ->
    error({incompatible_application, Application, Expected, Actual}).

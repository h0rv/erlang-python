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
    ok = code:add_paths(Directories),
    lists:foreach(fun({Name, Version, Spec}) ->
        case application:load(Spec) of
            ok -> ok;
            {error, {already_loaded, _}} -> ok
        end,
        {ok, Loaded} = application:get_key(Name, vsn),
        compatible(Name, list_to_binary(Version), list_to_binary(Loaded))
    end, Specs),
    lists:foreach(fun({Name, _, _}) ->
        {ok, _} = application:ensure_all_started(Name)
    end, Specs),
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
    {Atom, Version, Spec}.

compatible(_Application, Version, Version) -> ok;
compatible(Application, Expected, Actual) ->
    error({incompatible_application, Application, Expected, Actual}).

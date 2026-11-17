-module(py_mnesia).
-export([ensure_started/2]).

ensure_started(Dir, CreateSchema) ->
    global:trans({?MODULE, self()}, fun() ->
        case mnesia:system_info(is_running) of
            no ->
                ok = filelib:ensure_dir(filename:join(Dir, "schema.DAT")),
                ok = application:set_env(mnesia, dir, Dir),
                case CreateSchema of
                    true ->
                        case mnesia:create_schema([node()]) of
                            ok -> ok;
                            {error, {_, {already_exists, _}}} -> ok;
                            Other -> error({schema, Other})
                        end;
                    false -> ok
                end,
                ok = application:start(mnesia);
            yes -> ok;
            OtherState -> error({mnesia_state, OtherState})
        end,
        case filename:absname(mnesia:system_info(directory)) of
            Dir -> ok;
            _ -> error(mnesia_directory_mismatch)
        end
    end, [node()]).

-module(rebar3_codetracer_prv).

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, codetracer).

init(State) ->
    Provider = providers:create([
        {name, ?PROVIDER},
        {module, ?MODULE},
        {bare, true},
        {deps, [app_discovery]},
        {example, "rebar3 as codetrace codetracer --out-dir ct-traces"},
        {opts, [
            {out_dir, $o, "out-dir", string, "Trace output directory"},
            {format, $f, "format", string, "Trace format: ctfs, binary, json"},
            {build_dir, undefined, "build-dir", string, "Isolated recorder build directory"},
            {source_dir, undefined, "source-dir", string, "Additional source directory copied into the trace bundle"},
            {include_app, undefined, "include-app", string, "App name to include"},
            {exclude_app, undefined, "exclude-app", string, "App name to exclude"},
            {include_module, undefined, "include-module", string, "Module glob to include"},
            {exclude_module, undefined, "exclude-module", string, "Module glob to exclude"},
            {source_map, undefined, "source-map", string, "Source-map JSON file or directory"},
            {root_mfa, undefined, "root-mfa", string, "Root module:function/arity"},
            {eval, undefined, "eval", string, "Erlang expression for rebar3 shell --eval"},
            {profile, undefined, "profile", string, "Rebar3 profile used for nested compile and shell commands"},
            {capture_messages, undefined, "capture-messages", string, "Record BEAM messages"},
            {parse_transform, undefined, "parse-transform", undefined, "Use Erlang parse-transform compatibility mode"}
        ]},
        {short_desc, "Record a Rebar3 Erlang app with CodeTracer"},
        {desc, "Builds isolated CodeTracer instrumentation for the codetrace profile and records a real rebar3 shell invocation."}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    try
        Config = config(State),
        Apps = selected_apps(Config),
                SourceDirs = app_source_dirs(Apps) ++ config_strings(source_dir, Config),
        case SourceDirs of
            [] -> {error, {?MODULE, "codetracer found no Erlang source directories"}};
            _ ->
                BuildDir = config_string(build_dir, Config, filename:join(["_build", "codetrace", "codetracer"])),
                OutDir = config_string(out_dir, Config, "ct-traces"),
                Format = config_string(format, Config, "ctfs"),
                Recorder = recorder_binary(),
                Mode = mode(Config),
                ok = compile_profile(Mode, Config, BuildDir),
                ok = run_recorder_compile(Recorder, BuildDir, SourceDirs, Config),
                ok = maybe_rewrite_parse_transform_build(Mode, BuildDir, Apps),
                ok = run_recorder_record(Recorder, BuildDir, OutDir, Format, Apps, Config),
                rebar_api:info("codetracer wrote trace to ~s using ~s mode", [OutDir, atom_to_list(Mode)]),
                {ok, State}
        end
    catch
        Class:Reason:Stack ->
            {error, {?MODULE, io_lib:format("~p:~p~n~p", [Class, Reason, Stack])}}
    end.

format_error(Reason) ->
    io_lib:format("~s", [Reason]).

config(State) ->
    Base = rebar_state:get(State, codetracer, []),
    {Args, _} = rebar_state:command_parsed_args(State),
    merge_cli(Args, Base).

merge_cli([], Config) ->
    Config;
merge_cli([{Key, Value} | Rest], Config) ->
    merge_cli(Rest, [{Key, Value} | Config]);
merge_cli([Key | Rest], Config) when is_atom(Key) ->
    merge_cli(Rest, [{Key, true} | Config]).

mode(Config) ->
    case config_bool(parse_transform, Config, false) of
        true -> parse_transform;
        false -> provider
    end.

config_string(Key, Config, Default) ->
    case proplists:get_value(Key, Config) of
        undefined -> Default;
        Value when is_atom(Value) -> atom_to_list(Value);
        Value when is_binary(Value) -> binary_to_list(Value);
        Value -> Value
    end.

config_bool(Key, Config, Default) ->
    case proplists:get_value(Key, Config) of
        undefined -> Default;
        true -> true;
        false -> false;
        "true" -> true;
        "1" -> true;
        "false" -> false;
        "0" -> false;
        _ -> Default
    end.

config_strings(Key, Config) ->
    Values = proplists:get_all_values(Key, Config),
    lists:flatmap(fun normalize_strings/1, Values).

normalize_strings(undefined) -> [];
normalize_strings(Value) when is_atom(Value) -> [atom_to_list(Value)];
normalize_strings(Value) when is_binary(Value) -> [binary_to_list(Value)];
normalize_strings(Value) when is_list(Value) ->
    case io_lib:printable_list(Value) of
        true -> [Value];
        false -> lists:flatmap(fun normalize_strings/1, Value)
    end;
normalize_strings(Value) -> [io_lib:format("~p", [Value])].

selected_apps(Config) ->
    Apps0 =
        case filelib:is_dir("apps") of
            true -> [{filename:basename(filename:dirname(Src)), Src} || Src <- filelib:wildcard("apps/*/src")];
            false -> [{simple_app_name(), "src"}]
        end,
    Include = config_strings(include_app, Config),
    Exclude = config_strings(exclude_app, Config),
    Apps1 = [App || App = {Name, _Src} <- Apps0, (Include =:= [] orelse lists:member(Name, Include))],
    [App || App = {Name, _Src} <- Apps1, not lists:member(Name, Exclude)].

simple_app_name() ->
    case filelib:wildcard("src/*.app.src") of
        [Path | _] -> filename:basename(Path, ".app.src");
        [] -> filename:basename(filename:absname("."))
    end.

app_source_dirs(Apps) ->
    [Src || {_Name, Src} <- Apps, filelib:is_dir(Src)].

recorder_binary() ->
    case os:getenv("CODETRACER_BEAM_RECORDER_BIN") of
        false ->
            case os:getenv("CODETRACER_ELIXIR_RECORDER_BIN") of
                false -> "codetracer-beam-recorder";
                Path -> Path
            end;
        Path -> Path
    end.

compile_profile(Mode, Config, BuildDir) ->
    Profile = config_string(profile, Config, "codetrace"),
    Env =
        case Mode of
            parse_transform ->
                MarkerDir = filename:join(BuildDir, "parse_transform_markers"),
                ok = filelib:ensure_dir(filename:join(MarkerDir, "dummy")),
                [{"CODETRACER_REBAR3_PARSE_TRANSFORM_MARKER_DIR", MarkerDir}];
            provider ->
                []
        end,
    run_command("rebar3", ["as", Profile, "compile"], Env).

run_recorder_compile(Recorder, BuildDir, SourceDirs, Config) ->
    Args =
        ["compile", "--build-dir", BuildDir]
        ++ repeated("--source-dir", SourceDirs)
        ++ repeated("--source-map", config_strings(source_map, Config))
        ++ repeated("--include-module", config_strings(include_module, Config))
        ++ repeated("--exclude-module", config_strings(exclude_module, Config)),
    run_command(Recorder, Args, []).

maybe_rewrite_parse_transform_build(provider, _BuildDir, _Apps) ->
    ok;
maybe_rewrite_parse_transform_build(parse_transform, BuildDir, Apps) ->
    case Apps of
        [{AppName, _Src} | _] ->
            Summary = filename:join(BuildDir, "standalone_build.json"),
            Ebin = filename:absname(filename:join(["_build", "codetrace", "lib", AppName, "ebin"])),
            {ok, Binary} = file:read_file(Summary),
            Rewritten = re:replace(
                binary_to_list(Binary),
                "(\"instrumented_ebin\"\\s*:\\s*\")[^\"]+(\")",
                "\\1" ++ binary_to_list(json_escape(Ebin)) ++ "\\2",
                [{return, binary}]
            ),
            file:write_file(Summary, Rewritten);
        [] ->
            ok
    end.

run_recorder_record(Recorder, BuildDir, OutDir, Format, Apps, Config) ->
    Profile = config_string(profile, Config, "codetrace"),
    RootMfa = config_string(root_mfa, Config, default_root_mfa(Apps)),
    Eval = config_string(eval, Config, eval_from_root_mfa(RootMfa)),
    CaptureMessages = config_string(capture_messages, Config, "true"),
    AppsCsv = string:join([Name || {Name, _Src} <- Apps], ","),
    Args =
        ["record",
         "--out-dir", OutDir,
         "--format", Format,
         "--build-dir", BuildDir,
         "--root-mfa", RootMfa,
         "--capture-messages", CaptureMessages,
         "--",
         "rebar3", "as", Profile, "shell", "--start-clean", "--apps", AppsCsv, "--eval", Eval],
    run_command(Recorder, Args, []).

default_root_mfa([{Name, _Src} | _]) ->
    Name ++ ":main/0";
default_root_mfa([]) ->
    "undefined:main/0".

eval_from_root_mfa(RootMfa) ->
    case string:split(RootMfa, ":", leading) of
        [Module, Rest] ->
            Function =
                case string:split(Rest, "/", leading) of
                    [Name, _Arity] -> Name;
                    [Name] -> Name
                end,
            Module ++ ":" ++ Function ++ "().";
        _ ->
            RootMfa ++ "."
    end.

repeated(_Flag, []) ->
    [];
repeated(Flag, [Value | Rest]) ->
    [Flag, Value | repeated(Flag, Rest)].

run_command(Command, Args, ExtraEnv) ->
    Env = [{"TMPDIR", tmpdir()} | ExtraEnv],
    Port = open_port({spawn_executable, find_executable(Command)}, [
        {args, Args},
        {env, Env},
        binary,
        exit_status,
        stderr_to_stdout,
        use_stdio
    ]),
    collect_port(Port, []).

find_executable(Command) ->
    case filename:pathtype(Command) of
        absolute -> Command;
        relative ->
            case os:find_executable(Command) of
                false -> Command;
                Path -> Path
            end
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            collect_port(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            error({command_failed, Status, binary_to_list(Output)})
    end.

tmpdir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.

json_escape(Text) ->
    iolist_to_binary(escape_json(Text)).

escape_json([]) ->
    [];
escape_json([$" | Rest]) ->
    [$\\, $" | escape_json(Rest)];
escape_json([$\\ | Rest]) ->
    [$\\, $\\ | escape_json(Rest)];
escape_json([Char | Rest]) ->
    [Char | escape_json(Rest)].

-module(codetracer_session).

-behaviour(application).
-behaviour(gen_server).

-export([start/2, stop/1]).
-export([start_session/1, stop_session/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    file = undefined,
    session_file = undefined,
    root_pid = undefined,
    root_thread_id = 1,
    pid_threads = #{},
    next_thread_id = 2,
    last_thread_id = undefined,
    exited_pids = #{},
    source_paths = [],
    manifest_paths = [],
    manifest_index = #{},
    trace_functions = [],
    started = false
}).

start(_Type, _Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop(_State) ->
    ok.

start_session(Options) when is_list(Options) ->
    case gen_server:call(?MODULE, {start_session, Options}, infinity) of
        {ok, _ThreadId} -> ok;
        Other -> Other
    end.

stop_session(Reason) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid -> gen_server:call(?MODULE, {stop_session, Reason}, infinity)
    end.

init([]) ->
    {ok, #state{}}.

handle_call({start_session, _Options}, _From, State = #state{started = true}) ->
    {reply, {ok, State#state.root_thread_id}, State};
handle_call({start_session, Options}, {RootPid, _Tag}, State) ->
    SessionFile = require_option(session_file, Options),
    SourcePaths = proplists:get_value(source_paths, Options, []),
    ManifestPaths = proplists:get_value(manifest_paths, Options, []),
    TraceFunctions = proplists:get_value(trace_functions, Options, []),
    ok = filelib:ensure_dir(SessionFile),
    {ok, File} = file:open(SessionFile, [write, {encoding, utf8}]),
    ThreadId = 1,
    RootPidText = pid_to_list(RootPid),
    ManifestIndex = build_manifest_index(TraceFunctions),
    {ok, LoadedManifests} = load_manifests(ManifestPaths),
    persistent_term:put({codetracer_elixir_recorder, manifests}, LoadedManifests),
    persistent_term:put({codetracer_elixir_recorder, manifest_index}, ManifestIndex),
    ok = write_manifest_loaded(File, ManifestPaths, LoadedManifests),
    ok = install_trace_patterns(TraceFunctions),
    ok = install_message_trace_patterns(),
    erlang:trace(RootPid, true, [call, procs, send, 'receive', set_on_spawn, {tracer, self()}]),
    ok = write_thread_event(File, "thread_start", ThreadId, RootPidText, SourcePaths),
    ok = write_thread_event(File, "thread_switch", ThreadId, RootPidText, SourcePaths),
    {reply, {ok, ThreadId}, State#state{
        file = File,
        session_file = SessionFile,
        root_pid = RootPidText,
        root_thread_id = ThreadId,
        pid_threads = #{RootPidText => ThreadId},
        next_thread_id = 2,
        last_thread_id = ThreadId,
        source_paths = SourcePaths,
        manifest_paths = ManifestPaths,
        manifest_index = ManifestIndex,
        trace_functions = TraceFunctions,
        started = true
    }};
handle_call({stop_session, Reason}, _From, State = #state{started = true, file = File}) ->
    DeliveryRef = flush_trace_delivery(),
    StateAfterDrain = drain_trace_messages(File, State),
    ok = disable_traces(StateAfterDrain),
    ok = clear_message_trace_patterns(),
    ok = clear_trace_patterns(StateAfterDrain#state.trace_functions),
    persistent_term:erase({codetracer_elixir_recorder, manifests}),
    persistent_term:erase({codetracer_elixir_recorder, manifest_index}),
    ok = write_thread_event(
        File,
        "thread_exit",
        StateAfterDrain#state.root_thread_id,
        StateAfterDrain#state.root_pid,
        StateAfterDrain#state.source_paths
    ),
    ok = write_delivered(File, Reason, DeliveryRef),
    ok = file:sync(File),
    ok = file:close(File),
    {reply, ok, #state{}};
handle_call({stop_session, _Reason}, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(Message, State = #state{started = true, file = File}) ->
    case write_trace_message(File, Message, State) of
        {ok, NewState} -> {noreply, NewState};
        ignore -> {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State = #state{started = true}) ->
    catch handle_call({stop_session, terminate}, {self(), make_ref()}, State),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

require_option(Key, Options) ->
    case proplists:get_value(Key, Options) of
        undefined -> error({missing_required_option, Key});
        Value -> Value
    end.

trace_function_mfa({Module, Function, Arity, _Kind, _SourcePath, _Line}) ->
    {Module, Function, Arity};
trace_function_mfa({Module, Function, Arity, _Kind, _SourcePath, _Line, _ManifestId, _FunctionKey, _LocationId, _ClauseId, _ResolvedSourcePath, _ResolvedLine, _ResolvedColumn, _ResolutionStrategy, _TraceCopyPath}) ->
    {Module, Function, Arity}.

build_manifest_index(TraceFunctions) ->
    lists:foldl(
        fun(FunctionSpec, Acc) ->
            {Module, Function, Arity} = trace_function_mfa(FunctionSpec),
            maps:put({Module, Function, Arity}, trace_function_metadata(FunctionSpec), Acc)
        end,
        #{},
        TraceFunctions
    ).

trace_function_metadata({_Module, _Function, _Arity, _Kind, SourcePath, Line}) ->
    #{
        manifest_id => undefined,
        function_key => undefined,
        location_id => undefined,
        clause_id => undefined,
        source_location => #{
            build_path => SourcePath,
            trace_copy_path => SourcePath,
            line => Line,
            column => undefined,
            resolution => "erl_anno"
        }
    };
trace_function_metadata({_Module, _Function, _Arity, _Kind, _SourcePath, _Line, ManifestId, FunctionKey, LocationId, ClauseId, ResolvedSourcePath, ResolvedLine, ResolvedColumn, ResolutionStrategy, TraceCopyPath}) ->
    #{
        manifest_id => ManifestId,
        function_key => FunctionKey,
        location_id => LocationId,
        clause_id => ClauseId,
        source_location => #{
            build_path => ResolvedSourcePath,
            trace_copy_path => TraceCopyPath,
            line => ResolvedLine,
            column => ResolvedColumn,
            resolution => ResolutionStrategy
        }
    }.

load_manifests(ManifestPaths) ->
    Loaded =
        lists:map(
            fun(Path) ->
                {ok, Binary} = file:read_file(Path),
                #{path => Path, encoding => "json", bytes => byte_size(Binary), json => Binary}
            end,
            ManifestPaths
        ),
    {ok, Loaded}.

write_manifest_loaded(File, ManifestPaths, LoadedManifests) ->
    Line = [
        "{\"event\":\"manifest_loaded\",",
        "\"schema\":\"codetracer.beam.module-manifest.v1\",",
        "\"encoding\":\"json\",",
        "\"persistent_term_key\":\"{codetracer_elixir_recorder,manifests}\",",
        "\"manifest_count\":", integer_to_list(length(LoadedManifests)), ",",
        "\"manifest_paths\":[", join_json_strings(ManifestPaths), "]",
        "}\n"
    ],
    ok = file:write(File, Line).

install_trace_patterns(TraceFunctions) ->
    MatchSpec = [{'_', [], [{return_trace}, {exception_trace}]}],
    lists:foreach(
        fun(FunctionSpec) ->
            {Module, Function, Arity} = trace_function_mfa(FunctionSpec),
            _ = code:ensure_loaded(Module),
            _ = erlang:trace_pattern({Module, Function, Arity}, MatchSpec, [local])
        end,
        TraceFunctions
    ),
    ok.

install_message_trace_patterns() ->
    _ = erlang:trace_pattern(send, true, []),
    _ = erlang:trace_pattern('receive', [{['_', '$1', '_'], [], [{message, '$1'}]}], []),
    ok.

clear_message_trace_patterns() ->
    _ = erlang:trace_pattern(send, false, []),
    _ = erlang:trace_pattern('receive', false, []),
    ok.

clear_trace_patterns(TraceFunctions) ->
    lists:foreach(
        fun(FunctionSpec) ->
            {Module, Function, Arity} = trace_function_mfa(FunctionSpec),
            _ = erlang:trace_pattern({Module, Function, Arity}, false, [local])
        end,
        TraceFunctions
    ),
    ok.

disable_traces(#state{pid_threads = PidThreads}) ->
    maps:fold(
        fun(PidText, _ThreadId, ok) ->
            case list_to_pid_safe(PidText) of
                {ok, Pid} ->
                    _ = catch erlang:trace(Pid, false, [call, procs, send, 'receive', set_on_spawn]),
                    ok;
                error ->
                    ok
            end
        end,
        ok,
        PidThreads
    ).

list_to_pid_safe(Text) ->
    try {ok, list_to_pid(Text)}
    catch
        error:badarg -> error
    end.

flush_trace_delivery() ->
    Ref = erlang:trace_delivered(all),
    receive
        {trace_delivered, all, Ref} ->
            Ref
    end.

drain_trace_messages(File, State) ->
    receive
        Message ->
            NewState =
                case write_trace_message(File, Message, State) of
                    {ok, UpdatedState} -> UpdatedState;
                    ignore -> State
                end,
            drain_trace_messages(File, NewState)
    after 0 ->
        State
    end.

write_trace_message(File, {trace, Pid, call, {Module, Function, Args}}, State0) ->
    {ThreadId, State} = ensure_event_thread(File, Pid, State0),
    Metadata = source_metadata(Module, Function, length(Args), State),
    Line = [
        "{\"event\":\"call\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(length(Args)), ",",
        source_metadata_json(Metadata), ",",
        "\"args\":[", join_json_terms(Args), "]",
        "}\n"
    ],
    ok = file:write(File, Line),
    {ok, State};
write_trace_message(File, {trace, Pid, return_from, {Module, Function, Arity}, ReturnValue}, State0) ->
    {ThreadId, State} = ensure_event_thread(File, Pid, State0),
    Line = [
        "{\"event\":\"return_from\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(Arity), ",",
        "\"return_value\":", json_term(ReturnValue),
        "}\n"
    ],
    ok = file:write(File, Line),
    {ok, State};
write_trace_message(File, {trace, Pid, exception_from, {Module, Function, Arity}, {Class, Reason}}, State0) ->
    {ThreadId, State} = ensure_event_thread(File, Pid, State0),
    Line = [
        "{\"event\":\"exception_from\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(Arity), ",",
        "\"class\":", json_string(atom_to_list(Class)), ",",
        "\"reason\":", json_term(Reason), ",",
        "\"reason_repr\":", json_string(io_lib:format("~0tp", [Reason])),
        "}\n"
    ],
    ok = file:write(File, Line),
    {ok, State};
write_trace_message(File, {trace, Pid, spawn, ChildPid, {Module, Function, Args}}, State0) ->
    {_ParentThreadId, State1} = ensure_event_thread(File, Pid, State0),
    {_ChildThreadId, State} = ensure_pid_thread(File, ChildPid, State1),
    Line = [
        "{\"event\":\"process_spawn\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"child_pid\":", json_string(pid_to_list(ChildPid)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(length(Args)),
        "}\n"
    ],
    ok = file:write(File, Line),
    {ok, State};
write_trace_message(File, {trace, Pid, spawned, ParentPid, {Module, Function, Args}}, State0) ->
    {ThreadId, State} = ensure_event_thread(File, Pid, State0),
    Line = [
        "{\"event\":\"process_spawned\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"parent_pid\":", json_string(pid_to_list(ParentPid)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(length(Args)),
        "}\n"
    ],
    ok = file:write(File, Line),
    {ok, State};
write_trace_message(File, {trace, Pid, exit, Reason}, State0) ->
    {ThreadId, State1} = ensure_event_thread(File, Pid, State0),
    PidText = pid_to_list(Pid),
    case maps:is_key(PidText, State1#state.exited_pids) of
        true ->
            {ok, State1};
        false ->
            Line = [
                "{\"event\":\"thread_exit\",",
                "\"pid\":", json_string(PidText), ",",
                "\"root_pid\":", json_string(PidText), ",",
                "\"thread_id\":", integer_to_list(ThreadId), ",",
                "\"reason\":", json_term(Reason),
                "}\n"
            ],
            ok = file:write(File, Line),
            {ok, State1#state{exited_pids = maps:put(PidText, true, State1#state.exited_pids)}}
    end;
write_trace_message(File, {trace, Pid, send, Message, Recipient}, State0) ->
    {SenderThreadId, State1} = ensure_event_thread(File, Pid, State0),
    {RecipientPidText, RecipientThreadId, State} = recipient_thread(File, Recipient, State1),
    ok = write_message_event(
        File,
        "message_send",
        "send",
        Pid,
        SenderThreadId,
        RecipientPidText,
        RecipientThreadId,
        Message
    ),
    {ok, State};
write_trace_message(File, {trace, Pid, send_to_non_existing_process, Message, Recipient}, State0) ->
    {SenderThreadId, State} = ensure_event_thread(File, Pid, State0),
    ok = write_message_event(
        File,
        "message_send",
        "send_to_non_existing_process",
        Pid,
        SenderThreadId,
        recipient_text(Recipient),
        undefined,
        Message
    ),
    {ok, State};
write_trace_message(File, {trace, Pid, 'receive', Message, Sender}, State0) ->
    {RecipientThreadId, State1} = ensure_event_thread(File, Pid, State0),
    {SenderPidText, SenderThreadId, State} = sender_thread(File, Sender, State1),
    ok = write_message_event(
        File,
        "message_receive",
        "receive",
        SenderPidText,
        SenderThreadId,
        pid_to_list(Pid),
        RecipientThreadId,
        Message
    ),
    {ok, State};
write_trace_message(File, {trace, Pid, 'receive', Message}, State0) ->
    {RecipientThreadId, State} = ensure_event_thread(File, Pid, State0),
    ok = write_message_event(
        File,
        "message_receive",
        "receive",
        undefined,
        undefined,
        pid_to_list(Pid),
        RecipientThreadId,
        Message
    ),
    {ok, State};
write_trace_message(_File, _Message, _State) ->
    ignore.

source_metadata(Module, Function, Arity, #state{manifest_index = ManifestIndex}) ->
    maps:get({Module, Function, Arity}, ManifestIndex, #{
        manifest_id => undefined,
        function_key => undefined,
        location_id => undefined,
        clause_id => undefined,
        source_location => #{
            build_path => "<unknown>",
            trace_copy_path => "generated/<unknown>",
            line => 1,
            column => undefined,
            resolution => "unknown_generated_fallback"
        }
    }).

source_metadata_json(Metadata) ->
    SourceLocation = maps:get(source_location, Metadata),
    [
        "\"manifest_id\":", json_nullable_string(maps:get(manifest_id, Metadata)), ",",
        "\"function_key\":", json_nullable_string(maps:get(function_key, Metadata)), ",",
        "\"location_id\":", json_nullable_integer(maps:get(location_id, Metadata)), ",",
        "\"clause_id\":", json_nullable_integer(maps:get(clause_id, Metadata)), ",",
        "\"source_location\":{",
        "\"build_path\":", json_string(maps:get(build_path, SourceLocation)), ",",
        "\"trace_copy_path\":", json_string(maps:get(trace_copy_path, SourceLocation)), ",",
        "\"line\":", integer_to_list(maps:get(line, SourceLocation)), ",",
        "\"column\":", json_nullable_integer(maps:get(column, SourceLocation)), ",",
        "\"resolution\":", json_string(maps:get(resolution, SourceLocation)),
        "}"
    ].

write_thread_event(File, Event, ThreadId, RootPid, SourcePaths) ->
    Line = [
        "{\"event\":\"", Event, "\",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"pid\":", json_string(RootPid), ",",
        "\"root_pid\":", json_string(RootPid), ",",
        "\"source_paths\":[", join_json_strings(SourcePaths), "]",
        "}\n"
    ],
    ok = file:write(File, Line).

write_delivered(File, Reason, DeliveryRef) ->
    Line = [
        "{\"event\":\"trace_delivered\",",
        "\"delivery_target\":\"all\",",
        "\"delivery_ref\":", json_string(io_lib:format("~p", [DeliveryRef])), ",",
        "\"reason\":", json_string(io_lib:format("~p", [Reason])),
        "}\n"
    ],
    ok = file:write(File, Line).

ensure_event_thread(File, Pid, State0) ->
    {ThreadId, State1} = ensure_pid_thread(File, Pid, State0),
    case State1#state.last_thread_id of
        ThreadId ->
            {ThreadId, State1};
        _ ->
            ok = write_thread_event(
                File,
                "thread_switch",
                ThreadId,
                pid_to_list(Pid),
                State1#state.source_paths
            ),
            {ThreadId, State1#state{last_thread_id = ThreadId}}
    end.

ensure_pid_thread(File, Pid, State = #state{pid_threads = PidThreads}) when is_pid(Pid) ->
    PidText = pid_to_list(Pid),
    case maps:get(PidText, PidThreads, undefined) of
        undefined ->
            ThreadId = State#state.next_thread_id,
            ok = write_thread_event(File, "thread_start", ThreadId, PidText, State#state.source_paths),
            {ThreadId, State#state{
                pid_threads = maps:put(PidText, ThreadId, PidThreads),
                next_thread_id = ThreadId + 1
            }};
        ThreadId ->
            {ThreadId, State}
    end.

recipient_thread(File, Recipient, State) when is_pid(Recipient) ->
    {ThreadId, NewState} = ensure_pid_thread(File, Recipient, State),
    {pid_to_list(Recipient), ThreadId, NewState};
recipient_thread(_File, Recipient, State) ->
    {recipient_text(Recipient), undefined, State}.

sender_thread(File, Sender, State) when is_pid(Sender) ->
    {ThreadId, NewState} = ensure_pid_thread(File, Sender, State),
    {pid_to_list(Sender), ThreadId, NewState};
sender_thread(_File, Sender, State) ->
    {sender_text(Sender), undefined, State}.

recipient_text(undefined) ->
    undefined;
recipient_text(Recipient) when is_pid(Recipient) ->
    pid_to_list(Recipient);
recipient_text(Recipient) ->
    io_lib:format("~0tp", [Recipient]).

sender_text(undefined) ->
    undefined;
sender_text(Sender) when is_pid(Sender) ->
    pid_to_list(Sender);
sender_text(Sender) ->
    io_lib:format("~0tp", [Sender]).

write_message_event(
    File,
    Event,
    TraceTag,
    SenderPid,
    SenderThreadId,
    RecipientPid,
    RecipientThreadId,
    Message
) ->
    {MessageRepr, MessageTruncated} = bounded_term(Message, 512),
    Line = [
        "{\"event\":\"", Event, "\",",
        "\"schema\":\"codetracer.beam.message.v1\",",
        "\"direction\":", json_string(message_direction(Event)), ",",
        "\"trace_tag\":", json_string(TraceTag), ",",
        "\"tag\":", json_string(message_tag(Message)), ",",
        "\"sender_pid\":", json_nullable_string(pid_text(SenderPid)), ",",
        "\"sender_thread_id\":", json_nullable_integer(SenderThreadId), ",",
        "\"recipient_pid\":", json_nullable_string(pid_text(RecipientPid)), ",",
        "\"recipient_thread_id\":", json_nullable_integer(RecipientThreadId), ",",
        "\"message_format\":\"erlang_external_text\",",
        "\"message_repr\":", json_string(MessageRepr), ",",
        "\"message_truncated\":", json_boolean(MessageTruncated),
        "}\n"
    ],
    ok = file:write(File, Line).

message_direction("message_send") ->
    "send";
message_direction("message_receive") ->
    "receive".

pid_text(undefined) ->
    undefined;
pid_text(Pid) when is_pid(Pid) ->
    pid_to_list(Pid);
pid_text(Text) ->
    Text.

message_tag(Message) when is_tuple(Message), tuple_size(Message) > 0 ->
    tag_text(element(1, Message));
message_tag(Message) ->
    tag_text(Message).

tag_text(Value) when is_atom(Value) ->
    atom_to_list(Value);
tag_text(Value) when is_integer(Value) ->
    "integer";
tag_text(Value) when is_binary(Value) ->
    "binary";
tag_text(Value) when is_list(Value) ->
    "list";
tag_text(Value) when is_tuple(Value) ->
    "tuple";
tag_text(Value) when is_pid(Value) ->
    "pid";
tag_text(_Value) ->
    "term".

bounded_term(Value, Limit) ->
    Text = lists:flatten(io_lib:format("~0tp", [Value])),
    case length(Text) > Limit of
        true ->
            {string:substr(Text, 1, Limit), true};
        false ->
            {Text, false}
    end.

join_json_strings([]) ->
    "";
join_json_strings([Value]) ->
    json_string(Value);
join_json_strings([Value | Rest]) ->
    [json_string(Value), ",", join_json_strings(Rest)].

join_json_terms([]) ->
    "";
join_json_terms([Value]) ->
    json_term(Value);
join_json_terms([Value | Rest]) ->
    [json_term(Value), ",", join_json_terms(Rest)].

json_term(Value) when is_integer(Value) ->
    integer_to_list(Value);
json_term(Value) when is_float(Value) ->
    io_lib:format("~p", [Value]);
json_term(true) ->
    "true";
json_term(false) ->
    "false";
json_term(Value) ->
    json_string(io_lib:format("~0tp", [Value])).

json_nullable_string(undefined) ->
    "null";
json_nullable_string(Value) ->
    json_string(Value).

json_nullable_integer(undefined) ->
    "null";
json_nullable_integer(nil) ->
    "null";
json_nullable_integer(Value) ->
    integer_to_list(Value).

json_boolean(true) ->
    "true";
json_boolean(false) ->
    "false".

json_string(Value) ->
    [$", escape_json(flatten_text(Value)), $"].

flatten_text(Value) when is_binary(Value) ->
    binary_to_list(Value);
flatten_text(Value) ->
    lists:flatten(Value).

escape_json([]) ->
    [];
escape_json([$" | Rest]) ->
    [$\\, $" | escape_json(Rest)];
escape_json([$\\ | Rest]) ->
    [$\\, $\\ | escape_json(Rest)];
escape_json([$\n | Rest]) ->
    [$\\, $n | escape_json(Rest)];
escape_json([$\r | Rest]) ->
    [$\\, $r | escape_json(Rest)];
escape_json([$\t | Rest]) ->
    [$\\, $t | escape_json(Rest)];
escape_json([Char | Rest]) ->
    [Char | escape_json(Rest)].

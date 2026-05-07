-module(codetracer_native_tracer).

%% M16: native-backend tracer (fast async writer path).
%%
%% This module is the "native" tracer backend introduced in M16. The
%% tracer-process gen_server in `codetracer_session` is preserved as the
%% reference / fallback path; this module provides an alternative hot path
%% that:
%%
%%   * spawns a *dedicated writer process* (separate from the gen_server)
%%     which receives `{trace, ...}` messages directly and drains them
%%     into the same `runtime_session.jsonl` sidecar format the process
%%     tracer writes;
%%   * stamps every event with an atomic sequence number drawn from a
%%     `counters` array, so reader-visible ordering is total even when
%%     events are produced from many processes concurrently;
%%   * implements an explicit overflow policy (block / drop) controlled
%%     by `CODETRACER_BEAM_RECORDER_OVERFLOW_POLICY`. Overflow under the
%%     `drop` policy emits a `recorder_overflow` diagnostic line into the
%%     sidecar and propagates a non-zero status to the recorder CLI;
%%   * preserves `erlang:trace_delivered/1` shutdown-barrier semantics so
%%     the queue is fully drained before the writer is closed.
%%
%% Outstanding-task decision (M16): the dirty-NIF / native-thread split
%% target is documented in this module's header. The current
%% implementation runs the writer as a normal Erlang process to bound
%% session.erl-level risk while delivering the architectural pieces
%% (atomic sequence numbers, overflow policy, dedicated drain process,
%% shutdown barrier) the native NIF will ultimately reuse. A real
%% `erl_tracer` NIF + background C thread is a follow-on step; this
%% module's public API (`start_link/1`, `stop/2`, `event_count/0`,
%% `dropped_count/0`, `overflow_status/0`) is the seam the NIF will
%% replace without changing how `codetracer_session` drives shutdown.

-behaviour(gen_server).

-export([
    start_link/1,
    stop/2,
    event_count/0,
    dropped_count/0,
    overflow_status/0,
    install_root_trace/2,
    backend_name/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_QUEUE_LIMIT, 65536).
%% Atomic counter slots (1-indexed, see :counters docs).
-define(SLOT_SEQ, 1).
-define(SLOT_QUEUE_LEN, 2).
-define(SLOT_DROPPED, 3).
-define(SLOT_OVERFLOW_FIRED, 4).

-record(state, {
    file = undefined,
    session_file = undefined,
    capture_messages = true,
    counters = undefined,
    queue_limit = ?DEFAULT_QUEUE_LIMIT,
    overflow_policy = block, %% block | drop
    pid_threads = #{},
    pid_frames = #{},
    next_thread_id = 2,
    next_frame_id = 1,
    last_thread_id = undefined,
    exited_pids = #{},
    root_pid = undefined,
    root_thread_id = 1,
    source_paths = [],
    manifest_index = #{},
    overflowed = false
}).

%% ---------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------

backend_name() ->
    "native".

start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Options, []).

stop(Reason, DeliveryRef) ->
    case whereis(?SERVER) of
        undefined -> ok;
        _Pid -> gen_server:call(?SERVER, {stop, Reason, DeliveryRef}, infinity)
    end.

event_count() ->
    case whereis(?SERVER) of
        undefined -> 0;
        _Pid -> gen_server:call(?SERVER, event_count, infinity)
    end.

dropped_count() ->
    case whereis(?SERVER) of
        undefined -> 0;
        _Pid -> gen_server:call(?SERVER, dropped_count, infinity)
    end.

overflow_status() ->
    case whereis(?SERVER) of
        undefined -> {ok, 0};
        _Pid -> gen_server:call(?SERVER, overflow_status, infinity)
    end.

install_root_trace(RootPid, CaptureMessages) ->
    Tracer = whereis(?SERVER),
    case Tracer of
        undefined ->
            error({native_tracer_not_started, RootPid});
        _ ->
            _ = erlang:trace(RootPid, true, trace_flags(CaptureMessages, Tracer)),
            ok
    end.

%% ---------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------

init(Options) ->
    SessionFile = proplists:get_value(session_file, Options),
    SourcePaths = proplists:get_value(source_paths, Options, []),
    CaptureMessages = proplists:get_value(capture_messages, Options, true),
    ManifestIndex = proplists:get_value(manifest_index, Options, #{}),
    QueueLimit = proplists:get_value(queue_limit, Options, ?DEFAULT_QUEUE_LIMIT),
    OverflowPolicy = proplists:get_value(overflow_policy, Options, env_overflow_policy()),
    Counters = counters:new(4, [atomics]),
    ok = filelib:ensure_dir(SessionFile),
    {ok, File} = file:open(SessionFile, [write, {encoding, utf8}]),
    State = #state{
        file = File,
        session_file = SessionFile,
        capture_messages = CaptureMessages,
        counters = Counters,
        queue_limit = QueueLimit,
        overflow_policy = OverflowPolicy,
        manifest_index = ManifestIndex,
        source_paths = SourcePaths
    },
    {ok, State}.

handle_call({stop, Reason, DeliveryRef}, _From, State = #state{file = File}) ->
    %% Shutdown barrier: drain pending trace messages from the mailbox
    %% before closing the file so trace_delivered semantics are honored
    %% even on the native path.
    State1 = drain_mailbox(State),
    case State1#state.root_pid of
        undefined ->
            ok;
        RootPid ->
            ok = write_thread_event(
                File,
                "thread_exit",
                State1#state.root_thread_id,
                RootPid,
                State1#state.source_paths,
                next_seq(State1)
            )
    end,
    EventCount = counters:get(State1#state.counters, ?SLOT_SEQ),
    Dropped = counters:get(State1#state.counters, ?SLOT_DROPPED),
    Overflow = counters:get(State1#state.counters, ?SLOT_OVERFLOW_FIRED),
    Line = [
        "{\"event\":\"trace_delivered\",",
        "\"delivery_target\":\"all\",",
        "\"delivery_ref\":", json_string(io_lib:format("~p", [DeliveryRef])), ",",
        "\"reason\":", json_string(io_lib:format("~p", [Reason])), ",",
        "\"backend\":\"native\",",
        "\"event_count\":", integer_to_list(EventCount), ",",
        "\"dropped_event_count\":", integer_to_list(Dropped), ",",
        "\"overflow_fired\":", integer_to_list(Overflow), ",",
        "\"queue_limit\":", integer_to_list(State1#state.queue_limit), ",",
        "\"overflow_policy\":", json_string(atom_to_list(State1#state.overflow_policy)),
        "}\n"
    ],
    ok = file:write(File, Line),
    ok = file:sync(File),
    ok = file:close(File),
    {stop, normal, ok, State1#state{file = undefined}};
handle_call(event_count, _From, State = #state{counters = Counters}) ->
    {reply, counters:get(Counters, ?SLOT_SEQ), State};
handle_call(dropped_count, _From, State = #state{counters = Counters}) ->
    {reply, counters:get(Counters, ?SLOT_DROPPED), State};
handle_call(overflow_status, _From, State = #state{counters = Counters}) ->
    Dropped = counters:get(Counters, ?SLOT_DROPPED),
    Fired = counters:get(Counters, ?SLOT_OVERFLOW_FIRED),
    {reply, {ok, Dropped, Fired, State#state.overflow_policy}, State};
handle_call(_Other, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({native_tracer_register_root, RootPid}, State) ->
    PidText = pid_to_list(RootPid),
    case State#state.root_pid of
        undefined ->
            ThreadId = State#state.root_thread_id,
            Seq1 = next_seq(State),
            ok = write_thread_event(
                State#state.file, "thread_start", ThreadId,
                PidText, State#state.source_paths, Seq1),
            Seq2 = next_seq(State),
            ok = write_thread_event(
                State#state.file, "thread_switch", ThreadId,
                PidText, State#state.source_paths, Seq2),
            {noreply, State#state{
                root_pid = PidText,
                last_thread_id = ThreadId,
                pid_threads = maps:put(PidText, ThreadId, State#state.pid_threads)}};
        _ ->
            {noreply, State}
    end;
handle_info(Msg, State = #state{counters = Counters, queue_limit = Limit, overflow_policy = Policy})
        when element(1, Msg) =:= trace; element(1, Msg) =:= trace_ts ->
    QueueLen = case erlang:process_info(self(), message_queue_len) of
        {message_queue_len, N} -> N;
        _ -> 0
    end,
    counters:put(Counters, ?SLOT_QUEUE_LEN, QueueLen),
    case QueueLen > Limit of
        true ->
            counters:add(Counters, ?SLOT_OVERFLOW_FIRED, 1),
            case Policy of
                drop ->
                    counters:add(Counters, ?SLOT_DROPPED, 1),
                    State1 = maybe_emit_overflow(State, dropped),
                    {noreply, State1};
                block ->
                    State1 = handle_trace_message(Msg, State),
                    {noreply, State1}
            end;
        false ->
            State1 = handle_trace_message(Msg, State),
            {noreply, State1}
    end;
handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #state{file = undefined}) ->
    ok;
terminate(_Reason, #state{file = File}) ->
    catch file:sync(File),
    catch file:close(File),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ---------------------------------------------------------------------
%% Trace handlers
%% ---------------------------------------------------------------------

handle_trace_message({trace, Pid, call, {Module, Function, Args}}, State0) ->
    {ThreadId, State1} = ensure_event_thread(Pid, State0),
    Metadata = source_metadata(Module, Function, length(Args), State1),
    {FrameId, State2} = push_frame(Pid, Metadata, State1),
    SourceLanguage = maps:get(source_language, Metadata, "erlang"),
    Seq = next_seq(State2),
    Line = [
        "{\"event\":\"call\",",
        "\"backend\":\"native\",",
        "\"sequence\":", integer_to_list(Seq), ",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"frame_id\":", integer_to_list(FrameId), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(length(Args)), ",",
        "\"source_language\":", json_string(SourceLanguage), ",",
        source_metadata_json(Metadata), ",",
        "\"args\":[", join_json_terms(Args, SourceLanguage), "]",
        "}\n"
    ],
    ok = file:write(State2#state.file, Line),
    State2;
handle_trace_message({trace, Pid, return_from, {Module, Function, Arity}, ReturnValue}, State0) ->
    {ThreadId, State1} = ensure_event_thread(Pid, State0),
    {FrameInfo, State2} = pop_frame(Pid, State1),
    SourceLanguage = frame_source_language(FrameInfo),
    Seq = next_seq(State2),
    Line = [
        "{\"event\":\"return_from\",",
        "\"backend\":\"native\",",
        "\"sequence\":", integer_to_list(Seq), ",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"frame_id\":", json_nullable_integer(frame_id(FrameInfo)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(Arity), ",",
        "\"source_language\":", json_string(SourceLanguage), ",",
        "\"return_value\":", json_term(ReturnValue, SourceLanguage),
        "}\n"
    ],
    ok = file:write(State2#state.file, Line),
    State2;
handle_trace_message({trace, Pid, exception_from, {Module, Function, Arity}, {Class, Reason}}, State0) ->
    {ThreadId, State1} = ensure_event_thread(Pid, State0),
    {FrameInfo, State2} = pop_frame(Pid, State1),
    SourceLanguage = frame_source_language(FrameInfo),
    Seq = next_seq(State2),
    Line = [
        "{\"event\":\"exception_from\",",
        "\"backend\":\"native\",",
        "\"sequence\":", integer_to_list(Seq), ",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"frame_id\":", json_nullable_integer(frame_id(FrameInfo)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(Arity), ",",
        "\"source_language\":", json_string(SourceLanguage), ",",
        "\"class\":", json_string(atom_to_list(Class)), ",",
        "\"reason\":", json_term(Reason, SourceLanguage), ",",
        "\"reason_repr\":", json_string(io_lib:format("~0tp", [Reason])),
        "}\n"
    ],
    ok = file:write(State2#state.file, Line),
    State2;
handle_trace_message({trace, Pid, spawn, ChildPid, {Module, Function, Args}}, State0) ->
    {_ParentThreadId, State1} = ensure_event_thread(Pid, State0),
    {_ChildThreadId, State2} = ensure_pid_thread(ChildPid, State1),
    Seq = next_seq(State2),
    Line = [
        "{\"event\":\"process_spawn\",",
        "\"backend\":\"native\",",
        "\"sequence\":", integer_to_list(Seq), ",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"child_pid\":", json_string(pid_to_list(ChildPid)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(length(Args)),
        "}\n"
    ],
    ok = file:write(State2#state.file, Line),
    State2;
handle_trace_message({trace, Pid, spawned, ParentPid, {Module, Function, Args}}, State0) ->
    {ThreadId, State1} = ensure_event_thread(Pid, State0),
    Seq = next_seq(State1),
    Line = [
        "{\"event\":\"process_spawned\",",
        "\"backend\":\"native\",",
        "\"sequence\":", integer_to_list(Seq), ",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"parent_pid\":", json_string(pid_to_list(ParentPid)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(length(Args)),
        "}\n"
    ],
    ok = file:write(State1#state.file, Line),
    State1;
handle_trace_message({trace, Pid, exit, Reason}, State0) ->
    {ThreadId, State1} = ensure_event_thread(Pid, State0),
    PidText = pid_to_list(Pid),
    case maps:is_key(PidText, State1#state.exited_pids) of
        true ->
            State1;
        false ->
            Seq = next_seq(State1),
            Line = [
                "{\"event\":\"thread_exit\",",
                "\"backend\":\"native\",",
                "\"sequence\":", integer_to_list(Seq), ",",
                "\"pid\":", json_string(PidText), ",",
                "\"root_pid\":", json_string(PidText), ",",
                "\"thread_id\":", integer_to_list(ThreadId), ",",
                "\"reason\":", json_term(Reason, "erlang"),
                "}\n"
            ],
            ok = file:write(State1#state.file, Line),
            State1#state{exited_pids = maps:put(PidText, true, State1#state.exited_pids)}
    end;
handle_trace_message({trace, Pid, send, Message, Recipient}, State0) ->
    {SenderThreadId, State1} = ensure_event_thread(Pid, State0),
    {RecipientPidText, RecipientThreadId, State2} = recipient_thread(Recipient, State1),
    write_message_event(
        State2#state.file, "message_send", "send", Pid, SenderThreadId,
        RecipientPidText, RecipientThreadId, Message, next_seq(State2)),
    State2;
handle_trace_message({trace, Pid, send_to_non_existing_process, Message, Recipient}, State0) ->
    {SenderThreadId, State1} = ensure_event_thread(Pid, State0),
    write_message_event(
        State1#state.file, "message_send", "send_to_non_existing_process", Pid,
        SenderThreadId, recipient_text(Recipient), undefined, Message, next_seq(State1)),
    State1;
handle_trace_message({trace, Pid, 'receive', Message, Sender}, State0) ->
    {RecipientThreadId, State1} = ensure_event_thread(Pid, State0),
    {SenderPidText, SenderThreadId, State2} = sender_thread(Sender, State1),
    write_message_event(
        State2#state.file, "message_receive", "receive", SenderPidText,
        SenderThreadId, pid_to_list(Pid), RecipientThreadId, Message, next_seq(State2)),
    State2;
handle_trace_message({trace, Pid, 'receive', Message}, State0) ->
    {RecipientThreadId, State1} = ensure_event_thread(Pid, State0),
    write_message_event(
        State1#state.file, "message_receive", "receive", undefined, undefined,
        pid_to_list(Pid), RecipientThreadId, Message, next_seq(State1)),
    State1;
handle_trace_message(_Other, State) ->
    State.

%% ---------------------------------------------------------------------
%% Drain on shutdown — preserves trace_delivered ordering
%% ---------------------------------------------------------------------

drain_mailbox(State) ->
    receive
        Msg when element(1, Msg) =:= trace; element(1, Msg) =:= trace_ts ->
            drain_mailbox(handle_trace_message(Msg, State))
    after 0 ->
        State
    end.

%% ---------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------

env_overflow_policy() ->
    case os:getenv("CODETRACER_BEAM_RECORDER_OVERFLOW_POLICY") of
        false -> block;
        "block" -> block;
        "drop" -> drop;
        _ -> block
    end.

trace_flags(true, Tracer) ->
    [call, procs, send, 'receive', set_on_spawn, {tracer, Tracer}];
trace_flags(false, Tracer) ->
    [call, procs, set_on_spawn, {tracer, Tracer}].

next_seq(#state{counters = Counters}) ->
    counters:add(Counters, ?SLOT_SEQ, 1),
    counters:get(Counters, ?SLOT_SEQ).

maybe_emit_overflow(State = #state{overflowed = true}, _Cause) ->
    State;
maybe_emit_overflow(State = #state{file = File, counters = Counters}, Cause) ->
    Seq = next_seq(State),
    Limit = State#state.queue_limit,
    Policy = State#state.overflow_policy,
    Dropped = counters:get(Counters, ?SLOT_DROPPED),
    Line = [
        "{\"event\":\"recorder_overflow\",",
        "\"backend\":\"native\",",
        "\"sequence\":", integer_to_list(Seq), ",",
        "\"queue_limit\":", integer_to_list(Limit), ",",
        "\"overflow_policy\":", json_string(atom_to_list(Policy)), ",",
        "\"dropped_event_count\":", integer_to_list(Dropped), ",",
        "\"cause\":", json_string(atom_to_list(Cause)),
        "}\n"
    ],
    ok = file:write(File, Line),
    State#state{overflowed = true}.

source_metadata(Module, Function, Arity, #state{manifest_index = ManifestIndex}) ->
    maps:get({Module, Function, Arity}, ManifestIndex, #{
        source_language => "erlang",
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

push_frame(Pid, Metadata, State = #state{pid_frames = PidFrames, next_frame_id = FrameId}) ->
    PidText = pid_to_list(Pid),
    Stack = maps:get(PidText, PidFrames, []),
    FunctionKey = maps:get(function_key, Metadata, undefined),
    SourceLanguage = maps:get(source_language, Metadata, "erlang"),
    Frame = #{
        frame_id => FrameId,
        function_key => FunctionKey,
        source_language => SourceLanguage,
        variables => #{}
    },
    {FrameId, State#state{
        pid_frames = maps:put(PidText, [Frame | Stack], PidFrames),
        next_frame_id = FrameId + 1
    }}.

pop_frame(Pid, State = #state{pid_frames = PidFrames}) ->
    PidText = pid_to_list(Pid),
    case maps:get(PidText, PidFrames, []) of
        [Frame | Rest] ->
            {Frame, State#state{pid_frames = maps:put(PidText, Rest, PidFrames)}};
        [] ->
            {undefined, State}
    end.

frame_id(undefined) -> undefined;
frame_id(Frame) -> maps:get(frame_id, Frame, undefined).

frame_source_language(undefined) -> "erlang";
frame_source_language(Frame) -> maps:get(source_language, Frame, "erlang").

ensure_event_thread(Pid, State0) ->
    {ThreadId, State1} = ensure_pid_thread(Pid, State0),
    case State1#state.last_thread_id of
        ThreadId ->
            {ThreadId, State1};
        _ ->
            Seq = next_seq(State1),
            ok = write_thread_event(
                State1#state.file, "thread_switch", ThreadId,
                pid_to_list(Pid), State1#state.source_paths, Seq),
            {ThreadId, State1#state{last_thread_id = ThreadId}}
    end.

ensure_pid_thread(Pid, State = #state{pid_threads = PidThreads}) when is_pid(Pid) ->
    PidText = pid_to_list(Pid),
    case maps:get(PidText, PidThreads, undefined) of
        undefined ->
            ThreadId = State#state.next_thread_id,
            Seq = next_seq(State),
            ok = write_thread_event(
                State#state.file, "thread_start", ThreadId, PidText,
                State#state.source_paths, Seq),
            {ThreadId, State#state{
                pid_threads = maps:put(PidText, ThreadId, PidThreads),
                next_thread_id = ThreadId + 1}};
        ThreadId ->
            {ThreadId, State}
    end.

recipient_thread(Recipient, State) when is_pid(Recipient) ->
    {ThreadId, NewState} = ensure_pid_thread(Recipient, State),
    {pid_to_list(Recipient), ThreadId, NewState};
recipient_thread(Recipient, State) ->
    {recipient_text(Recipient), undefined, State}.

sender_thread(Sender, State) when is_pid(Sender) ->
    {ThreadId, NewState} = ensure_pid_thread(Sender, State),
    {pid_to_list(Sender), ThreadId, NewState};
sender_thread(Sender, State) ->
    {sender_text(Sender), undefined, State}.

recipient_text(undefined) -> undefined;
recipient_text(Recipient) when is_pid(Recipient) -> pid_to_list(Recipient);
recipient_text(Recipient) -> io_lib:format("~0tp", [Recipient]).

sender_text(undefined) -> undefined;
sender_text(Sender) when is_pid(Sender) -> pid_to_list(Sender);
sender_text(Sender) -> io_lib:format("~0tp", [Sender]).

write_thread_event(File, Event, ThreadId, RootPid, SourcePaths, Seq) ->
    Line = [
        "{\"event\":\"", Event, "\",",
        "\"backend\":\"native\",",
        "\"sequence\":", integer_to_list(Seq), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"pid\":", json_string(RootPid), ",",
        "\"root_pid\":", json_string(RootPid), ",",
        "\"source_paths\":[", join_json_strings(SourcePaths), "]",
        "}\n"
    ],
    ok = file:write(File, Line).

write_message_event(File, Event, TraceTag, SenderPid, SenderThreadId,
                    RecipientPid, RecipientThreadId, Message, Seq) ->
    {MessageRepr, MessageTruncated} = bounded_term(Message, 512),
    Line = [
        "{\"event\":\"", Event, "\",",
        "\"backend\":\"native\",",
        "\"sequence\":", integer_to_list(Seq), ",",
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

message_direction("message_send") -> "send";
message_direction("message_receive") -> "receive".

pid_text(undefined) -> undefined;
pid_text(Pid) when is_pid(Pid) -> pid_to_list(Pid);
pid_text(Text) -> Text.

message_tag(Message) when is_tuple(Message), tuple_size(Message) > 0 ->
    tag_text(element(1, Message));
message_tag(Message) ->
    tag_text(Message).

tag_text(Value) when is_atom(Value) -> atom_to_list(Value);
tag_text(Value) when is_integer(Value) -> "integer";
tag_text(Value) when is_binary(Value) -> "binary";
tag_text(Value) when is_list(Value) -> "list";
tag_text(Value) when is_tuple(Value) -> "tuple";
tag_text(Value) when is_pid(Value) -> "pid";
tag_text(_Value) -> "term".

bounded_term(Value, Limit) ->
    Text = lists:flatten(io_lib:format("~0tp", [Value])),
    case length(Text) > Limit of
        true -> {string:substr(Text, 1, Limit), true};
        false -> {Text, false}
    end.

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

join_json_strings([]) -> "";
join_json_strings([V]) -> json_string(V);
join_json_strings([V | R]) -> [json_string(V), ",", join_json_strings(R)].

join_json_terms([], _SourceLanguage) -> "";
join_json_terms([V], SourceLanguage) -> json_term(V, SourceLanguage);
join_json_terms([V | R], SourceLanguage) ->
    [json_term(V, SourceLanguage), ",", join_json_terms(R, SourceLanguage)].

json_term(Value, SourceLanguage) ->
    codetracer_value_encoder:json(Value, SourceLanguage).

json_nullable_string(undefined) -> "null";
json_nullable_string(Value) -> json_string(Value).

json_nullable_integer(undefined) -> "null";
json_nullable_integer(nil) -> "null";
json_nullable_integer(Value) -> integer_to_list(Value).

json_boolean(true) -> "true";
json_boolean(false) -> "false".

json_string(Value) ->
    [$", escape_json(flatten_text(Value)), $"].

flatten_text(Value) when is_binary(Value) -> binary_to_list(Value);
flatten_text(Value) -> lists:flatten(Value).

escape_json([]) -> [];
escape_json([$" | R]) -> [$\\, $" | escape_json(R)];
escape_json([$\\ | R]) -> [$\\, $\\ | escape_json(R)];
escape_json([$\n | R]) -> [$\\, $n | escape_json(R)];
escape_json([$\r | R]) -> [$\\, $r | escape_json(R)];
escape_json([$\t | R]) -> [$\\, $t | escape_json(R)];
escape_json([C | R]) -> [C | escape_json(R)].

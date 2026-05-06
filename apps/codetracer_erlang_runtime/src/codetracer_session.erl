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
    source_paths = [],
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
    ok = filelib:ensure_dir(SessionFile),
    {ok, File} = file:open(SessionFile, [write, {encoding, utf8}]),
    ThreadId = 1,
    RootPidText = pid_to_list(RootPid),
    ok = write_thread_event(File, "thread_start", ThreadId, RootPidText, SourcePaths),
    ok = write_thread_event(File, "thread_switch", ThreadId, RootPidText, SourcePaths),
    {reply, {ok, ThreadId}, State#state{
        file = File,
        session_file = SessionFile,
        root_pid = RootPidText,
        root_thread_id = ThreadId,
        source_paths = SourcePaths,
        started = true
    }};
handle_call({stop_session, Reason}, _From, State = #state{started = true, file = File}) ->
    ok = write_thread_event(
        File,
        "thread_exit",
        State#state.root_thread_id,
        State#state.root_pid,
        State#state.source_paths
    ),
    DeliveryRef = flush_trace_delivery(),
    ok = write_delivered(File, Reason, DeliveryRef),
    ok = file:sync(File),
    ok = file:close(File),
    {reply, ok, #state{}};
handle_call({stop_session, _Reason}, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

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

flush_trace_delivery() ->
    Ref = erlang:trace_delivered(all),
    receive
        {trace_delivered, all, Ref} ->
            Ref
    end.

write_thread_event(File, Event, ThreadId, RootPid, SourcePaths) ->
    Line = [
        "{\"event\":\"", Event, "\",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
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

join_json_strings([]) ->
    "";
join_json_strings([Value]) ->
    json_string(Value);
join_json_strings([Value | Rest]) ->
    [json_string(Value), ",", join_json_strings(Rest)].

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

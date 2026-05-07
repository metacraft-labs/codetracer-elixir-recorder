%% M16 benchmark fixtures: deterministic, real BEAM workloads exercising
%% the three pressure axes (call-heavy, process-heavy, message-heavy).
%% The recorder runs each entrypoint under both `--tracer-backend
%% process` and `--tracer-backend native` and records wall-clock results
%% to benches/native_tracer_baseline.md.
-module(native_tracer_bench).

-export([call_heavy/0, process_heavy/0, message_heavy/0]).

%% Call-heavy: tight recursive computation. Without trace_pattern
%% installation, only the BEAM dispatch overhead is exercised; the
%% recorder still records process events.
call_heavy() ->
    R = sum(0, 1000),
    io:format("call-heavy ~w~n", [R]),
    ok.

sum(Acc, 0) -> Acc;
sum(Acc, N) -> sum(Acc + N, N - 1).

%% Process-heavy: many short-lived spawned processes that immediately
%% reply and exit. Stresses the process_spawn / thread_exit / process
%% tracing paths.
process_heavy() ->
    Parent = self(),
    Pids = [spawn(fun() -> Parent ! {self(), ok} end) || _ <- lists:seq(1, 200)],
    drain_replies(Pids),
    io:format("process-heavy ok~n"),
    ok.

drain_replies([]) -> ok;
drain_replies([Pid | Rest]) ->
    receive
        {Pid, ok} -> drain_replies(Rest)
    after 5000 ->
        error({timeout, Pid})
    end.

%% Message-heavy: a single sender pumps many messages to a single
%% receiver. Stresses the send/receive trace path through a single
%% tracer process.
message_heavy() ->
    Parent = self(),
    Receiver = spawn(fun() -> message_receiver_loop(Parent, 0, 1000) end),
    receive
        {ready, Receiver} -> ok
    end,
    [Receiver ! {ping, I} || I <- lists:seq(1, 1000)],
    receive
        {done, Receiver, 1000} ->
            io:format("message-heavy ok~n")
    end,
    ok.

message_receiver_loop(Parent, Seen, Total) when Seen =:= 0 ->
    Parent ! {ready, self()},
    message_receiver_loop_real(Parent, Seen, Total).

message_receiver_loop_real(Parent, Total, Total) ->
    Parent ! {done, self(), Total};
message_receiver_loop_real(Parent, Seen, Total) ->
    receive
        {ping, _Index} ->
            message_receiver_loop_real(Parent, Seen + 1, Total)
    end.

%%% Stress fixture: spawns processes that crash abruptly via
%%% erlang:exit/2, throw/1, and uncaught error/1, then waits for the
%%% trapped EXIT signal. The fixture asserts the parent observes every
%%% crash. The recorder must keep its writer state consistent under
%%% abrupt exits without losing the trace_delivered shutdown line.
-module(stress_crashes).
-export([main/0, crasher/2]).

-define(N, 64).

main() ->
    process_flag(trap_exit, true),
    Parent = self(),
    Pids = [spawn_link(?MODULE, crasher, [Parent, kind(I)]) || I <- lists:seq(1, ?N)],
    ok = await_exits(Pids, []),
    io:format("stress-crashes-ok~n"),
    ok.

kind(I) ->
    case I rem 3 of
        0 -> exit_call;
        1 -> throw_call;
        2 -> error_call
    end.

crasher(_Parent, exit_call) ->
    exit(stress_crash_exit);
crasher(_Parent, throw_call) ->
    throw(stress_crash_throw);
crasher(_Parent, error_call) ->
    erlang:error(stress_crash_error).

await_exits([], Reasons) ->
    true = length(Reasons) =:= ?N,
    ok;
await_exits([Pid | Rest], Reasons) ->
    receive
        {'EXIT', Pid, Reason} -> await_exits(Rest, [Reason | Reasons])
    after 30000 ->
        erlang:error({stress_crashes_timeout, Pid})
    end.

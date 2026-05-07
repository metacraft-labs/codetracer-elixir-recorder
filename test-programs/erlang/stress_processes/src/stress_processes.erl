%%% Stress fixture: spawns a large number of short-lived processes that
%%% each compute a tiny result and exit. Each process generates one
%%% spawn, one call, one return, and one exit trace event. Used by the
%%% M17 stress verification to confirm the recorder handles many
%%% concurrent process lifecycles without mailbox blowup.
-module(stress_processes).
-export([main/0, worker/1]).

-define(N, 1000).

main() ->
    Parent = self(),
    Pids = [spawn(?MODULE, worker, [Parent]) || _ <- lists:seq(1, ?N)],
    ok = wait_for_replies(?N, 0),
    %% Wait for monitored child processes to flush before shutdown so
    %% the recorder sees their exit events.
    lists:foreach(fun(Pid) -> wait_exit(Pid) end, Pids),
    io:format("stress-processes-ok~n"),
    ok.

worker(Parent) ->
    Parent ! {worker_done, self(), 1},
    ok.

wait_for_replies(N, N) -> ok;
wait_for_replies(N, K) ->
    receive
        {worker_done, _, 1} -> wait_for_replies(N, K + 1)
    after 10000 ->
        erlang:error({stress_processes_timeout, N, K})
    end.

wait_exit(Pid) ->
    case erlang:is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(1),
            wait_exit(Pid)
    end.

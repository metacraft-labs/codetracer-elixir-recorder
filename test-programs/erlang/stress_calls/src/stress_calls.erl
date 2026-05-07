%%% Stress fixture: 100k+ traced call events through a tail-recursive
%%% accumulator. The fixture is deliberately tight (no allocations beyond
%%% the integer accumulator) so the dominant trace cost is the recorder
%%% writer, not the workload itself. Used by the M17 stress verification
%%% to confirm the recorder doesn't corrupt the bundle or grow without
%%% bound under sustained call/return pressure.
-module(stress_calls).
-export([main/0, loop/2]).

-define(N, 100000).

main() ->
    Result = loop(?N, 0),
    true = Result =:= ?N,
    io:format("stress-calls-ok ~p~n", [Result]),
    ok.

loop(0, Acc) ->
    Acc;
loop(N, Acc) when N > 0 ->
    loop(N - 1, Acc + 1).

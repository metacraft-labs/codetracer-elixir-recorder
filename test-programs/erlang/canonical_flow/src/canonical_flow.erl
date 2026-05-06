-module(canonical_flow).
-export([compute/0, main/0]).

compute() ->
    A = 10,
    B = 32,
    SumVal = A + B,
    Doubled = SumVal * 2,
    FinalResult = Doubled + A,
    true = FinalResult =:= 94,
    FinalResult.

main() ->
    Result = compute(),
    true = Result =:= 94,
    io:format("~p~n", [Result]),
    Result.

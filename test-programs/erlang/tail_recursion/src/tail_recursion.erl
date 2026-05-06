-module(tail_recursion).
-export([count_down/2, small/0, main/0]).

count_down(0, Acc) ->
    Acc;
count_down(N, Acc) when N > 0 ->
    count_down(N - 1, Acc + 1).

small() ->
    Result = count_down(3, 0),
    true = Result =:= 3,
    io:format("~p~n", [Result]),
    Result.

main() ->
    Result = count_down(5000, 0),
    true = Result =:= 5000,
    io:format("~p~n", [Result]),
    Result.

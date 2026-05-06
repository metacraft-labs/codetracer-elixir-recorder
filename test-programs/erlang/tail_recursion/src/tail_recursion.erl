-module(tail_recursion).
-export([count_down/2, main/0]).

count_down(0, Acc) ->
    Acc;
count_down(N, Acc) when N > 0 ->
    count_down(N - 1, Acc + 1).

main() ->
    Result = count_down(5000, 0),
    true = Result =:= 5000,
    io:format("~p~n", [Result]),
    Result.

-module(generated_bridge).
-export([compute/0, main/0]).

compute() ->
    A = 40,
    B = 2,
    A + B.

main() ->
    Result = compute(),
    io:format("mapped-ok:~p~n", [Result]),
    Result.

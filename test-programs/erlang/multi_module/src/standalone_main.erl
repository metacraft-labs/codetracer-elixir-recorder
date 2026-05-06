-module(standalone_main).

-export([main/0, value/0]).

main() ->
    Result = value() + standalone_helper:bonus(20),
    io:format("m11-multi:~p~n", [Result]),
    Result.

value() ->
    22.

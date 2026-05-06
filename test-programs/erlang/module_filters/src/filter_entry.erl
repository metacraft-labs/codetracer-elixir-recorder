-module(filter_entry).

-export([main/0]).

main() ->
    Kept = filter_keep:run(10),
    Skipped = filter_skip:run(7),
    Result = Kept + Skipped,
    io:format("m11-filter:~p~n", [Result]),
    Result.

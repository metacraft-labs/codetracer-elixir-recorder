-module(spawn_messages).
-export([main/0, flood/0]).

main() ->
    Parent = self(),
    Child = spawn(fun() -> child(Parent) end),
    receive
        {spawn_child_started, Child} ->
            ok
    end,
    Child ! {spawn_ping, Parent, 41},
    receive
        {spawn_pong, Child, 42} ->
            io:format("spawn-ok~n")
    end,
    ok.

child(Parent) ->
    Parent ! {spawn_child_started, self()},
    receive
        {spawn_ping, Parent, 41} ->
            Parent ! {spawn_pong, self(), 42}
    end.

flood() ->
    Parent = self(),
    Count = 64,
    Child = spawn(fun() -> flood_child(Parent, Count, 0) end),
    receive
        {flush_child_ready, Child} ->
            ok
    end,
    lists:foreach(fun(Index) -> Child ! {flush_ping, Index} end, lists:seq(1, Count)),
    receive
        {flush_done, Child, Count} ->
            io:format("flush-ok~n")
    end,
    ok.

flood_child(Parent, Count, Seen) ->
    Parent ! {flush_child_ready, self()},
    flood_loop(Parent, Count, Seen).

flood_loop(Parent, Count, Count) ->
    Parent ! {flush_done, self(), Count};
flood_loop(Parent, Count, Seen) ->
    receive
        {flush_ping, Index} when Index =:= Seen + 1 ->
            flood_loop(Parent, Count, Seen + 1)
    end.

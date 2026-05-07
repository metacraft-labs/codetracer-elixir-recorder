%%% Stress fixture: exercises the recorder under large binaries and
%%% large maps. The workload constructs a 256 KiB binary, a 4 KiB
%%% binary, and a 1024-key map, then asserts on their content so the
%%% optimizer cannot drop the work. The recorder must survive without
%%% out-of-memory or producer-side back-pressure issues.
-module(stress_terms).
-export([main/0]).

-define(BIG_BIN_SIZE, 262144).
-define(SMALL_BIN_SIZE, 4096).
-define(MAP_SIZE, 1024).

main() ->
    BigBin = make_binary(?BIG_BIN_SIZE),
    SmallBin = make_binary(?SMALL_BIN_SIZE),
    Map = make_map(?MAP_SIZE),

    true = byte_size(BigBin) =:= ?BIG_BIN_SIZE,
    true = byte_size(SmallBin) =:= ?SMALL_BIN_SIZE,
    true = map_size(Map) =:= ?MAP_SIZE,
    true = maps:get(0, Map) =:= 0,
    true = maps:get(?MAP_SIZE - 1, Map) =:= ?MAP_SIZE - 1,

    io:format("stress-terms-ok ~p ~p ~p~n",
              [byte_size(BigBin), byte_size(SmallBin), map_size(Map)]),
    ok.

make_binary(Size) ->
    list_to_binary([<<(I band 16#FF):8>> || I <- lists:seq(0, Size - 1)]).

make_map(Size) ->
    lists:foldl(fun(I, Acc) -> maps:put(I, I, Acc) end, #{}, lists:seq(0, Size - 1)).

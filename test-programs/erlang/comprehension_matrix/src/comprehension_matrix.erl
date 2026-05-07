-module(comprehension_matrix).

-export([main/0]).

main() ->
    Numbers = lists:seq(1, 8),
    ListSquares = [N * N || N <- Numbers, N rem 2 =:= 0],
    ListScore = lists:sum(ListSquares),

    NestedPairs = [{A, B, A + B} || A <- [1, 2, 3], B <- [10, 20], (A + B) rem 2 =:= 1],
    PairScore = lists:sum([Total || {_A, _B, Total} <- NestedPairs]),

    BinaryInput = <<0, 255, 16, 65, 5>>,
    BinaryFiltered = << <<Byte>> || <<Byte:8>> <= BinaryInput, Byte =/= 16 >>,
    BinaryFilterScore = lists:sum([Byte || <<Byte:8>> <= BinaryFiltered]),

    BinaryListGen = << <<(N * 3):8>> || N <- [1, 2, 3] >>,
    BinaryListScore = lists:sum([Byte || <<Byte:8>> <= BinaryListGen]),

    SourceMap = #{alpha => 3, beta => 4, gamma => 5, delta => 6},
    MapFiltered = #{Key => Value * 10 || Key := Value <- SourceMap, Value rem 2 =:= 1},
    MapGenScore = maps:get(alpha, MapFiltered) + maps:get(gamma, MapFiltered) + map_size(MapFiltered),

    MapFromPairs = #{Key => Value + 1 || {Key, Value} <- [{left, 7}, {right, 8}]},
    MapListScore = maps:get(left, MapFromPairs) + maps:get(right, MapFromPairs) + map_size(MapFromPairs),

    CrossMap = #{{Key, N} => Value + N || Key := Value <- SourceMap, N <- [1, 2], Value =< 4},
    CrossMapScore = lists:sum(maps:values(CrossMap)) + map_size(CrossMap),

    FinalTotal = ListScore
        + PairScore
        + BinaryFilterScore
        + BinaryListScore
        + MapGenScore
        + MapListScore
        + CrossMapScore,
    _UseAll = {
        ListSquares,
        NestedPairs,
        BinaryFiltered,
        BinaryListGen,
        MapFiltered,
        MapFromPairs,
        CrossMap
    },
    io:format("comprehension-matrix-ok:~p~n", [FinalTotal]),
    ok.

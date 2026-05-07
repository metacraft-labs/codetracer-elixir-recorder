-module(reference_edges).

-export([main/0]).

main() ->
    Id = 7,
    DynamicKey = {<<"metric">>, Id},
    CreatedMap = #{DynamicKey => 40, static => 2},
    UpdateKey = DynamicKey,
    UpdatedMap = CreatedMap#{UpdateKey := 41, {extra, Id} => 5},
    MatchKey = {<<"metric">>, 7},
    #{MatchKey := Matched, static := Static} = UpdatedMap,
    ExtraKey = {extra, Id},
    #{ExtraKey := ExtraValue} = UpdatedMap,
    MapScore = Matched + Static + ExtraValue + map_size(UpdatedMap),

    Payload = <<"metacraft">>,
    PayloadSize = byte_size(Payload),
    BitsSize = 8,
    TypedBinary = <<
        PayloadSize:8/unsigned-integer,
        Payload:PayloadSize/binary,
        513:16/little-unsigned-integer,
        -3:8/signed-integer,
        5:BitsSize/unsigned-integer,
        2.5:64/float
    >>,
    <<
        SegmentSize:8/unsigned-integer,
        Segment:SegmentSize/binary,
        Little:16/little-unsigned-integer,
        Signed:8/signed-integer,
        Tiny:BitsSize/unsigned-integer,
        FloatValue:64/float
    >> = TypedBinary,
    true = Segment =:= Payload,
    BinaryScore = SegmentSize
        + byte_size(Segment)
        + Little
        + Signed
        + Tiny
        + trunc(FloatValue * 10),

    Request = <<"GET /edge HTTP/1.1">>,
    <<"GET ", PathAndVersion/binary>> = Request,
    <<Path:5/binary, " HTTP/1.1">> = PathAndVersion,
    PrefixScore = byte_size(PathAndVersion) + byte_size(Path) + binary:first(Path),

    {{tag, Shared}, Shared = {inner, Inner}} =
        {{tag, {inner, 23}}, {inner, 23}},
    {First = {ordered, OrderedValue}, First} = {{ordered, 19}, {ordered, 19}},
    PatternScore = Inner + OrderedValue + tuple_size(Shared) + tuple_size(First),

    FinalTotal = MapScore + BinaryScore + PrefixScore + PatternScore,
    _UseAll = {
        CreatedMap,
        UpdatedMap,
        TypedBinary,
        Segment,
        Request,
        PathAndVersion,
        Path,
        Shared,
        First
    },
    io:format("reference-edges-ok:~p~n", [FinalTotal]),
    ok.

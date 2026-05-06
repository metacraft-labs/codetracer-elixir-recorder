-module(value_matrix).

-export([main/0, truncation/0]).

-record(person, {name, age}).

main() ->
    SmallInt = 42,
    BigInt = 1 bsl 80,
    Float = 3.25,
    TrueValue = true,
    FalseValue = false,
    AtomValue = sample_atom,
    TupleValue = {1, sample_atom, <<"tuple">>},
    EmptyList = [],
    ListValue = [1, 2, 3],
    StringBinary = <<"hello utf8">>,
    RawBinary = <<0, 255, 16, 65>>,
    InvalidUtf8Binary = <<255, 254, 253>>,
    SimpleMap = #{answer => 42, <<"name">> => <<"metacraft">>},
    ComplexMap = #{{complex, key} => value, 1 => one},
    RecordValue = #person{name = <<"Ada">>, age = 37},
    PidValue = self(),
    RefValue = make_ref(),
    PortValue = open_port({spawn, "cat"}, [binary]),
    FunValue = fun(X) -> X + 1 end,
    port_close(PortValue),
    _UseAll = {
        SmallInt,
        BigInt,
        Float,
        TrueValue,
        FalseValue,
        AtomValue,
        TupleValue,
        EmptyList,
        ListValue,
        StringBinary,
        RawBinary,
        InvalidUtf8Binary,
        SimpleMap,
        ComplexMap,
        RecordValue,
        PidValue,
        RefValue,
        PortValue,
        FunValue
    },
    io:format("value-matrix-ok~n"),
    ok.

truncation() ->
    Deep = [[[[[depth_limit]]]]],
    LongList = lists:seq(1, 20),
    LongString = binary:copy(<<"a">>, 64),
    LongRawBinary = binary:copy(<<0, 255, 16, 65>>, 20),
    LargeMap = maps:from_list([{list_to_atom("k" ++ integer_to_list(N)), N} || N <- lists:seq(1, 20)]),
    LargeComplexMap = maps:from_list([{{complex, N}, binary:copy(<<"a">>, 64)} || N <- lists:seq(1, 20)]),
    _UseAll = {Deep, LongList, LongString, LongRawBinary, LargeMap, LargeComplexMap},
    io:format("truncation-ok~n"),
    ok.

-module(codetracer_value_encoder).

-export([json/2, json/3, limits/0]).

-define(I64_MIN, -9223372036854775808).
-define(I64_MAX, 9223372036854775807).

limits() ->
    #{
        depth => env_int("CODETRACER_ELIXIR_VALUE_MAX_DEPTH", 5),
        sequence_items => env_int("CODETRACER_ELIXIR_VALUE_MAX_SEQUENCE_ITEMS", 100),
        binary_bytes => env_int("CODETRACER_ELIXIR_VALUE_MAX_BINARY_BYTES", 256),
        map_pairs => env_int("CODETRACER_ELIXIR_VALUE_MAX_MAP_PAIRS", 100),
        string_bytes => env_int("CODETRACER_ELIXIR_VALUE_MAX_STRING_BYTES", 1000)
    }.

json(Value, SourceLanguage) ->
    json(Value, SourceLanguage, limits()).

json(Value, SourceLanguage, Limits) ->
    encode(Value, normalize_language(SourceLanguage), Limits, maps:get(depth, Limits)).

env_int(Name, Default) ->
    case os:getenv(Name) of
        false ->
            Default;
        Text ->
            try
                Value = list_to_integer(Text),
                case Value >= 0 of
                    true -> Value;
                    false -> Default
                end
            catch
                _:_ -> Default
            end
    end.

normalize_language(undefined) ->
    "erlang";
normalize_language(Value) when is_atom(Value) ->
    atom_to_list(Value);
normalize_language(Value) when is_binary(Value) ->
    binary_to_list(Value);
normalize_language(Value) ->
    lists:flatten(Value).

encode(_Value, _SourceLanguage, _Limits, Depth) when Depth < 0 ->
    truncated_json("depth");
encode(Value, _SourceLanguage, Limits, _Depth) when is_integer(Value) ->
    encode_integer(Value, Limits);
encode(Value, _SourceLanguage, _Limits, _Depth) when is_float(Value) ->
    ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"float\",\"value\":", io_lib:format("~p", [Value]), ",\"type_kind\":\"Float\",\"lang_type\":\"float\"}"];
encode(true, _SourceLanguage, _Limits, _Depth) ->
    "{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"bool\",\"value\":true,\"type_kind\":\"Bool\",\"lang_type\":\"boolean\"}";
encode(false, _SourceLanguage, _Limits, _Depth) ->
    "{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"bool\",\"value\":false,\"type_kind\":\"Bool\",\"lang_type\":\"boolean\"}";
encode(nil, "elixir", _Limits, _Depth) ->
    "{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"none\",\"type_kind\":\"None\",\"lang_type\":\"nil\"}";
encode(Value, _SourceLanguage, _Limits, _Depth) when is_atom(Value) ->
    ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"atom\",\"value\":", json_string(atom_text(Value)), ",\"type_kind\":\"Raw\",\"lang_type\":\"atom\"}"];
encode(Value, _SourceLanguage, Limits, _Depth) when is_binary(Value) ->
    encode_binary(Value, Limits);
encode(Value, SourceLanguage, Limits, Depth) when is_list(Value) ->
    encode_list(Value, SourceLanguage, Limits, Depth);
encode(Value, SourceLanguage, Limits, Depth) when is_tuple(Value) ->
    encode_tuple(Value, SourceLanguage, Limits, Depth);
encode(Value, SourceLanguage, Limits, Depth) when is_map(Value) ->
    encode_map(Value, SourceLanguage, Limits, Depth);
encode(Value, _SourceLanguage, _Limits, _Depth) when is_pid(Value) ->
    raw_json("pid", "Ref", pid_to_list(Value));
encode(Value, _SourceLanguage, _Limits, _Depth) when is_reference(Value) ->
    raw_json("reference", "Ref", io_lib:format("~0tp", [Value]));
encode(Value, _SourceLanguage, _Limits, _Depth) when is_port(Value) ->
    raw_json("port", "Ref", erlang:port_to_list(Value));
encode(Value, _SourceLanguage, _Limits, _Depth) when is_function(Value) ->
    raw_json("fun", "FunctionKind", io_lib:format("~0tp", [Value]));
encode(Value, _SourceLanguage, _Limits, _Depth) ->
    raw_json("term", "Raw", io_lib:format("~0tp", [Value])).

encode_integer(Value, _Limits) when Value >= ?I64_MIN, Value =< ?I64_MAX ->
    ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"int\",\"value\":", integer_to_list(Value), ",\"type_kind\":\"Int\",\"lang_type\":\"integer\"}"];
encode_integer(Value, Limits) ->
    MaxBytes = maps:get(binary_bytes, Limits),
    {Bytes, Truncated} = bigint_bytes(abs(Value), MaxBytes),
    case Truncated of
        true ->
            ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"raw\",\"value\":", json_string("[bigint truncated]"), ",\"type_kind\":\"NonExpanded\",\"lang_type\":\"integer\"}"];
        false ->
            [
                "{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"bigint\",\"negative\":",
                bool_text(Value < 0),
                ",\"bytes_hex\":",
                json_string(hex(Bytes)),
                ",\"type_kind\":\"Int\",\"lang_type\":\"integer\"}"
            ]
    end.

bigint_bytes(0, _MaxBytes) ->
    {[0], false};
bigint_bytes(Value, MaxBytes) ->
    bigint_bytes(Value, MaxBytes, []).

bigint_bytes(0, _Remaining, Acc) ->
    {Acc, false};
bigint_bytes(_Value, 0, Acc) ->
    {Acc, true};
bigint_bytes(Value, Remaining, Acc) ->
    Byte = Value band 16#ff,
    bigint_bytes(Value bsr 8, Remaining - 1, [Byte | Acc]).

encode_binary(Binary, Limits) ->
    StringLimit = maps:get(string_bytes, Limits),
    case bounded_utf8(Binary, StringLimit) of
        {ok, Text, Truncated} ->
            case has_binary_control_bytes(Binary, StringLimit) of
                false ->
                    Suffix = case Truncated of true -> "..."; false -> "" end,
                    ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"string\",\"value\":", json_string(Text ++ Suffix), ",\"truncated\":", bool_text(Truncated), ",\"type_kind\":\"String\",\"lang_type\":\"binary\"}"];
                true ->
                    encode_raw_binary(Binary, Limits)
            end;
        error ->
            encode_raw_binary(Binary, Limits)
    end.

encode_raw_binary(Binary, Limits) ->
            MaxBytes = maps:get(binary_bytes, Limits),
            Size = byte_size(Binary),
            Take = min(Size, MaxBytes),
            Prefix = binary:part(Binary, 0, Take),
            Truncated = Size > Take,
            Repr = "0x" ++ hex(binary_to_list(Prefix)) ++ case Truncated of true -> "..."; false -> "" end,
            ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"raw\",\"value\":", json_string(Repr), ",\"truncated\":", bool_text(Truncated), ",\"type_kind\":\"Raw\",\"lang_type\":\"binary\"}"].

has_binary_control_bytes(Binary, Limit) ->
    Size = byte_size(Binary),
    Take = min(Size, Limit),
    has_binary_control_bytes(binary:part(Binary, 0, Take)).

has_binary_control_bytes(<<>>) ->
    false;
has_binary_control_bytes(<<Byte, _Rest/binary>>) when Byte < 16#20, Byte =/= $\n, Byte =/= $\r, Byte =/= $\t ->
    true;
has_binary_control_bytes(<<_Byte, Rest/binary>>) ->
    has_binary_control_bytes(Rest).

bounded_utf8(Binary, Limit) ->
    Size = byte_size(Binary),
    Take0 = min(Size, Limit),
    case Size > Take0 of
        true ->
            bounded_utf8_prefix(Binary, Take0, true, 4);
        false ->
            case unicode:characters_to_list(Binary, utf8) of
                Text when is_list(Text) -> {ok, Text, false};
                _ -> error
            end
    end.

bounded_utf8_prefix(_Binary, _Take, _Truncated, 0) ->
    error;
bounded_utf8_prefix(_Binary, Take, _Truncated, _Attempts) when Take < 0 ->
    error;
bounded_utf8_prefix(Binary, Take, Truncated, Attempts) when Take >= 0 ->
    Prefix = binary:part(Binary, 0, Take),
    case unicode:characters_to_list(Prefix, utf8) of
        Text when is_list(Text) ->
            {ok, Text, Truncated orelse Take < byte_size(Binary)};
        _ ->
            bounded_utf8_prefix(Binary, Take - 1, true, Attempts - 1)
    end.

encode_list(Value, SourceLanguage, Limits, Depth) ->
    MaxItems = maps:get(sequence_items, Limits),
    {Elements, Tail, Truncated} = bounded_list(Value, SourceLanguage, Limits, Depth, MaxItems),
    Extra =
        case {Tail, Truncated} of
            {[], false} -> [];
            {_, true} -> [truncated_json("sequence_items")];
            {_, false} -> [raw_json("improper_list_tail", "Raw", io_lib:format("~0tp", [Tail]))]
        end,
    Items = Elements ++ Extra,
    ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"list\",\"type_kind\":\"Seq\",\"lang_type\":\"list\",\"truncated\":", bool_text(Truncated), ",\"elements\":[", join_json(Items), "]}"].

bounded_list(Rest, _SourceLanguage, _Limits, _Depth, 0) ->
    {[], Rest, Rest =/= []};
bounded_list([], _SourceLanguage, _Limits, _Depth, _Remaining) ->
    {[], [], false};
bounded_list([Head | Tail], SourceLanguage, Limits, Depth, Remaining) ->
    {Items, FinalTail, Truncated} = bounded_list(Tail, SourceLanguage, Limits, Depth, Remaining - 1),
    {[encode(Head, SourceLanguage, Limits, Depth - 1) | Items], FinalTail, Truncated};
bounded_list(Tail, _SourceLanguage, _Limits, _Depth, _Remaining) ->
    {[], Tail, false}.

encode_tuple(Value, "erlang" = SourceLanguage, Limits, Depth) when tuple_size(Value) > 1, is_atom(element(1, Value)) ->
    encode_record_tuple(Value, SourceLanguage, Limits, Depth);
encode_tuple(Value, SourceLanguage, Limits, Depth) ->
    MaxItems = maps:get(sequence_items, Limits),
    Size = tuple_size(Value),
    Count = min(Size, MaxItems),
    Elements = [encode(element(Index, Value), SourceLanguage, Limits, Depth - 1) || Index <- lists:seq(1, Count)],
    Truncated = Size > Count,
    Items = case Truncated of true -> Elements ++ [truncated_json("sequence_items")]; false -> Elements end,
    ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"tuple\",\"type_kind\":\"Tuple\",\"lang_type\":\"tuple\",\"truncated\":", bool_text(Truncated), ",\"elements\":[", join_json(Items), "]}"].

encode_record_tuple(Value, SourceLanguage, Limits, Depth) ->
    MaxItems = maps:get(sequence_items, Limits),
    Size = tuple_size(Value),
    Tag = element(1, Value),
    FieldCount = min(Size - 1, MaxItems),
    Fields0 = [["{\"name\":\"__record_tag__\",\"value\":", encode(Tag, SourceLanguage, Limits, Depth - 1), "}"]],
    Fields =
        Fields0 ++
            [
                ["{\"name\":\"_", integer_to_list(Index - 1), "\",\"value\":", encode(element(Index, Value), SourceLanguage, Limits, Depth - 1), "}"]
             || Index <- lists:seq(2, FieldCount + 1)
            ],
    Truncated = (Size - 1) > FieldCount,
    FinalFields =
        case Truncated of
            true -> Fields ++ [["{\"name\":\"__truncated__\",\"value\":", truncated_json("sequence_items"), "}"]];
            false -> Fields
        end,
    ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"record\",\"record_tag\":", json_string(atom_text(Tag)), ",\"type_kind\":\"Struct\",\"lang_type\":", json_string("record:" ++ atom_text(Tag)), ",\"truncated\":", bool_text(Truncated), ",\"fields\":[", join_json(FinalFields), "]}"].

encode_map(Value, SourceLanguage, Limits, Depth) ->
    MaxPairs = maps:get(map_pairs, Limits),
    {Pairs, Truncated} = bounded_map_pairs(maps:iterator(Value), SourceLanguage, Limits, Depth, MaxPairs),
    case simple_map_pairs(Pairs) of
        true ->
            Fields = [
                ["{\"name\":", json_string(map_key_name(Key)), ",\"value\":", EncodedValue, "}"]
             || {Key, EncodedValue} <- Pairs
            ],
            FinalFields =
                case Truncated of
                    true -> Fields ++ [["{\"name\":\"__truncated__\",\"value\":", truncated_json("map_pairs"), "}"]];
                    false -> Fields
                end,
            ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"map_struct\",\"type_kind\":\"Struct\",\"lang_type\":\"map\",\"truncated\":", bool_text(Truncated), ",\"fields\":[", join_json(FinalFields), "]}"];
        false ->
            MaxBytes = maps:get(binary_bytes, Limits),
            {Text, WasTruncated} = bounded_term(Value, MaxBytes),
            raw_json("map", "Raw", Text ++ case WasTruncated of true -> "..."; false -> "" end)
    end.

bounded_map_pairs(Iterator, SourceLanguage, Limits, Depth, MaxPairs) ->
    bounded_map_pairs(Iterator, SourceLanguage, Limits, Depth, MaxPairs, []).

bounded_map_pairs(_Iterator, _SourceLanguage, _Limits, _Depth, 0, Acc) ->
    {lists:reverse(Acc), true};
bounded_map_pairs(Iterator, SourceLanguage, Limits, Depth, Remaining, Acc) ->
    case maps:next(Iterator) of
        none ->
            {lists:reverse(Acc), false};
        {Key, Value, Next} ->
            bounded_map_pairs(Next, SourceLanguage, Limits, Depth, Remaining - 1, [
                {Key, encode(Value, SourceLanguage, Limits, Depth - 1)} | Acc
            ])
    end.

simple_map_pairs(Pairs) ->
    lists:all(fun({Key, _Value}) -> is_simple_map_key(Key) end, Pairs).

is_simple_map_key(Key) when is_atom(Key) ->
    true;
is_simple_map_key(Key) when is_binary(Key) ->
    case bounded_utf8(Key, byte_size(Key)) of
        {ok, _Text, false} -> true;
        _ -> false
    end;
is_simple_map_key(_Key) ->
    false.

map_key_name(Key) when is_atom(Key) ->
    atom_text(Key);
map_key_name(Key) when is_binary(Key) ->
    {ok, Text, _Truncated} = bounded_utf8(Key, byte_size(Key)),
    Text.

bounded_term(Value, Limit) ->
    Text = lists:flatten(io_lib:write(Value, [{chars_limit, Limit}, {depth, 10}])),
    Truncated = (string:str(Text, "...") > 0) orelse length(Text) > Limit,
    {take_chars(Text, Limit), Truncated}.

take_chars(_Text, Limit) when Limit =< 0 ->
    "";
take_chars(Text, Limit) ->
    string:substr(Text, 1, min(length(Text), Limit)).

raw_json(LangType, TypeKind, Repr) ->
    ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"raw\",\"value\":", json_string(Repr), ",\"type_kind\":", json_string(TypeKind), ",\"lang_type\":", json_string(LangType), "}"].

truncated_json(Reason) ->
    ["{\"ct_value_schema\":\"codetracer.beam.value.v1\",\"kind\":\"truncated\",\"reason\":", json_string(Reason), ",\"value\":\"[truncated]\",\"type_kind\":\"NonExpanded\",\"lang_type\":\"truncated\"}"].

join_json([]) ->
    "";
join_json([Value]) ->
    Value;
join_json([Value | Rest]) ->
    [Value, ",", join_json(Rest)].

json_string(Value) ->
    [$", escape_json(lists:flatten(Value)), $"].

escape_json([]) ->
    [];
escape_json([$" | Rest]) ->
    [$\\, $" | escape_json(Rest)];
escape_json([$\\ | Rest]) ->
    [$\\, $\\ | escape_json(Rest)];
escape_json([$\n | Rest]) ->
    [$\\, $n | escape_json(Rest)];
escape_json([$\r | Rest]) ->
    [$\\, $r | escape_json(Rest)];
escape_json([$\t | Rest]) ->
    [$\\, $t | escape_json(Rest)];
escape_json([Char | Rest]) when Char < 16#20 ->
    io_lib:format("\\u~4.16.0B", [Char]) ++ escape_json(Rest);
escape_json([Char | Rest]) ->
    [Char | escape_json(Rest)].

atom_text(Value) ->
    atom_to_list(Value).

bool_text(true) ->
    "true";
bool_text(false) ->
    "false".

hex(Bytes) ->
    lists:flatten([io_lib:format("~2.16.0B", [Byte]) || Byte <- Bytes]).

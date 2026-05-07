-module(syntax_matrix).
-feature(maybe_expr, enable).

-export([exported_increment/1, main/0]).

-import(lists, [sum/1]).

main() ->
    Chained = {ok, Pair = {Left, Right}} = {ok, {21, 21}},
    true = Chained =:= {ok, Pair},

    [Head | Tail] = [9, 8, 7],
    Diff = [alpha, beta, gamma, beta] -- [beta, gamma],
    ListScore = Head + length(Tail) + length(Diff),

    CreatedMap = #{left => Left, right => Right},
    UpdatedMap = CreatedMap#{right := Right + 1, total => Left + Right + 1},
    #{left := MapLeft, right := MapRight, total := MapTotal} = UpdatedMap,

    Packed = <<255:8, MapRight:8, MapTotal:16/big-unsigned-integer>>,
    <<ByteA:8, ByteB:8, Wide:16/big-unsigned-integer>> = Packed,

    CompareScore =
        case {MapLeft < MapRight, {alpha, MapLeft} < {alpha, MapRight}, MapTotal =:= Wide} of
            {true, true, true} -> 3
        end,
    BitScore = (Wide rem 10)
        + ((MapLeft band 15) bor (MapRight bxor 2))
        + (1 bsl 3)
        + (16 bsr 2)
        + (bnot -3),

    BoolStrict = (true and true) and ((false or true) and (true xor false)) and (not false),
    ShortA = false andalso explode(),
    ShortB = true orelse explode(),
    BoolScore = bool_to_int(BoolStrict)
        + bool_to_int(ShortA =:= false)
        + bool_to_int(ShortB =:= true),

    ImportedTotal = sum([MapLeft, ByteB]),
    Applied = apply(?MODULE, exported_increment, [ImportedTotal]),

    LocalFun = fun local_double/1,
    LocalFunResult = LocalFun(20),
    RemoteFun = fun erlang:length/1,
    RemoteFunResult = RemoteFun([a, b, c, d]),
    Offset = 5,
    Closure = fun(N) -> N + Offset end,
    ClosureResult = Closure(10),
    Multi = fun
        ({add, X}) when X > 0 -> X + 1;
        ({tuple, A, B}) -> A + B;
        (_) -> 0
    end,
    MultiResult = Multi({add, 12}) + Multi({tuple, 6, 7}) + Multi(other),

    BeginResult =
        begin
            BeginLocal = LocalFunResult,
            BeginLocal + RemoteFunResult
        end,

    MaybeResult =
        maybe
            {ok, MaybeA} ?= {ok, ClosureResult},
            MaybeB = MaybeA + 2,
            {ok, MaybeB}
        else
            error -> {error, not_used};
            Other -> {unexpected, Other}
        end,
    {ok, MaybeScore} = MaybeResult,
    MaybeElseInput = maybe_error(),
    MaybeElse =
        maybe
            {ok, _Skipped} ?= MaybeElseInput,
            99
        else
            error -> 5
        end,

    FinalTotal = ListScore
        + MapTotal
        + ByteA
        + ByteB
        + Wide
        + CompareScore
        + BitScore
        + BoolScore
        + ImportedTotal
        + Applied
        + LocalFunResult
        + RemoteFunResult
        + ClosureResult
        + MultiResult
        + BeginResult
        + MaybeScore
        + MaybeElse,
    io:format("syntax-matrix-ok:~p~n", [FinalTotal]),
    ok.

exported_increment(Value) ->
    Value + 1.

local_double(Value) ->
    Value * 2.

maybe_error() ->
    error.

bool_to_int(true) ->
    1;
bool_to_int(false) ->
    0.

explode() ->
    erlang:error(short_circuit_operand_evaluated).

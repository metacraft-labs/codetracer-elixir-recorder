-module(exceptions_matrix).

-export([main/0]).

main() ->
    erase(exceptions_after),

    CatchThrow = catch throw({catch_expr_throw, 11}),
    CatchExit = catch exit({catch_expr_exit, 12}),

    TryThrowResult =
        try thrower(21) of
            ThrowValue -> {unexpected_throw_success, ThrowValue}
        catch
            throw:{thrown, ThrowN} -> {caught_throw, ThrowN}
        after
            mark_after(throw)
        end,

    TryErrorResult =
        try errorer(4) of
            ErrorValue -> {unexpected_error_success, ErrorValue}
        catch
            error:{bad_input, ErrorN} -> {caught_error, ErrorN}
        after
            mark_after(error)
        end,

    TryExitResult =
        try exiter(9) of
            ExitValue -> {unexpected_exit_success, ExitValue}
        catch
            exit:{exit_reason, ExitN} -> {caught_exit, ExitN}
        after
            mark_after(exit)
        end,

    TrySuccess =
        try succeed(5) of
            {ok, SuccessN} -> {success, SuccessN + 1}
        catch
            _:_ -> unexpected_success_catch
        after
            mark_after(success)
        end,

    AfterScore = after_score([throw, error, exit, success]),
    FinalTotal = caught_number(CatchThrow)
        + caught_exit_number(CatchExit)
        + caught_number(TryThrowResult)
        + caught_number(TryErrorResult)
        + caught_number(TryExitResult)
        + caught_number(TrySuccess)
        + AfterScore,
    _UseAll = {CatchThrow, CatchExit, TryThrowResult, TryErrorResult, TryExitResult, TrySuccess},
    io:format("exceptions-matrix-ok:~p~n", [FinalTotal]),
    ok.

thrower(Value) ->
    throw({thrown, Value}).

errorer(Value) ->
    erlang:error({bad_input, Value}).

exiter(Value) ->
    exit({exit_reason, Value}).

succeed(Value) ->
    {ok, Value}.

mark_after(Tag) ->
    Seen0 =
        case get(exceptions_after) of
            undefined -> [];
            Seen when is_list(Seen) -> Seen
        end,
    put(exceptions_after, lists:usort([Tag | Seen0])),
    ok.

after_score(Tags) ->
    Seen =
        case get(exceptions_after) of
            undefined -> [];
            Stored when is_list(Stored) -> Stored
        end,
    length([Tag || Tag <- Tags, lists:member(Tag, Seen)]).

caught_number({catch_expr_throw, Value}) ->
    Value;
caught_number({caught_throw, Value}) ->
    Value;
caught_number({caught_error, Value}) ->
    Value;
caught_number({caught_exit, Value}) ->
    Value;
caught_number({success, Value}) ->
    Value.

caught_exit_number({'EXIT', {catch_expr_exit, Value}}) ->
    Value.

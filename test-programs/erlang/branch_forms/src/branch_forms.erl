-module(branch_forms).
-export([main/0]).

choose(Value) ->
    case Value of
        1 ->
            case_one;
        _ ->
            case_other
    end.

guarded(Value) ->
    if
        Value > 0 ->
            if_positive;
        true ->
            if_non_positive
    end.

mailbox() ->
    self() ! {branch_msg, 7},
    receive
        {branch_msg, N} ->
            N + 1
    after 0 ->
            timeout
    end.

protect(Value) ->
    try
        10 div Value
    of
        Quotient ->
            {ok, Quotient}
    catch
        error:badarith ->
            {error, badarith}
    after
        ok
    end.

main() ->
    A = choose(1),
    B = guarded(2),
    C = mailbox(),
    D = protect(2),
    true = A =:= case_one,
    true = B =:= if_positive,
    true = C =:= 8,
    true = D =:= {ok, 5},
    io:format("branch-ok~n"),
    ok.

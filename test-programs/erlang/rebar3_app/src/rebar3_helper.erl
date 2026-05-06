-module(rebar3_helper).

-export([add/2]).

add(Left, Right) ->
    Sum = Left + Right,
    Sum.

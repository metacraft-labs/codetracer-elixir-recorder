-module(filter_keep).

-export([run/1]).

run(Input) ->
    Doubled = Input * 2,
    Doubled.

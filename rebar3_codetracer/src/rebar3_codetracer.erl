-module(rebar3_codetracer).

-export([init/1]).

init(State) ->
    rebar3_codetracer_prv:init(State).

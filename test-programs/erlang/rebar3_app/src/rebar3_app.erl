-module(rebar3_app).

-export([main/0]).

main() ->
    Base = rebar3_helper:add(20, 22),
    Generated = rebar3_generated:value(5),
    Base + Generated.

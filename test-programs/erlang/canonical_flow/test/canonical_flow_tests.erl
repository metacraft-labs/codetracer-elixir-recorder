-module(canonical_flow_tests).

-include_lib("eunit/include/eunit.hrl").

compute_returns_canonical_result_test() ->
    ?assertEqual(94, canonical_flow:compute()).

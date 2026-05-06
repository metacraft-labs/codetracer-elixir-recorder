-module(rebar3_shell).

-export([main/0]).

main() ->
    Parent = self(),
    Worker = spawn(fun() -> Parent ! {worker_result, 33 + 9} end),
    receive
        {worker_result, Value} ->
            {Worker, Value}
    after 1000 ->
        timeout
    end.

%%% Stress fixture: drives a worker process to accumulate a deep mailbox
%%% before draining it. Producers fire ?N messages back-to-back; the
%%% consumer receives them all and replies with the count. Exercises
%%% the recorder under sustained send/receive pressure with a non-empty
%%% message queue.
-module(stress_mailboxes).
-export([main/0, consumer/2]).

-define(N, 5000).

main() ->
    Parent = self(),
    Consumer = spawn(?MODULE, consumer, [Parent, ?N]),
    [Consumer ! {ping, I} || I <- lists:seq(1, ?N)],
    receive
        {drained, ?N} ->
            io:format("stress-mailboxes-ok~n"),
            ok
    after 30000 ->
        erlang:error(stress_mailboxes_timeout)
    end.

consumer(Parent, N) ->
    consume(Parent, N, 0).

consume(Parent, N, N) ->
    Parent ! {drained, N};
consume(Parent, N, Seen) ->
    receive
        {ping, _Index} -> consume(Parent, N, Seen + 1)
    end.

-module(receive_matrix).

-export([
    linked_worker/1,
    main/0,
    monitored_worker/1,
    spawn3_worker/1
]).

main() ->
    Parent = self(),

    Selective = selective_receive(),
    Timeout = timeout_branch(),
    Registered = registered_name_send(),
    Spawn3 = spawn3_roundtrip(Parent),
    Linked = spawn_link_cleanup(Parent),
    Monitor = spawn_monitor_down(Parent),

    true = Selective =:= {11, 31},
    true = Timeout =:= timeout_taken,
    true = Registered =:= 17,
    true = Spawn3 =:= 24,
    true = Linked =:= normal,
    true = Monitor =:= normal,

    io:format("receive-matrix-ok~n"),
    ok.

selective_receive() ->
    self() ! {leftover_message, delayed, 31},
    self() ! {selective_receive, chosen, 11},
    Selective =
        receive
            {selective_receive, chosen, SelectiveValue} ->
                SelectiveValue
        after 1000 ->
            exit(selective_receive_timeout)
        end,
    Leftover =
        receive
            {leftover_message, delayed, LeftoverValue} ->
                LeftoverValue
        after 1000 ->
            exit(leftover_message_timeout)
        end,
    {Selective, Leftover}.

timeout_branch() ->
    TimeoutResult =
        receive
            {timeout_probe, Value} ->
                {unexpected_message, Value}
        after 0 ->
            timeout_taken
        end,
    self() ! {timeout_result, TimeoutResult},
    receive
        {timeout_result, timeout_taken} ->
            timeout_taken
    after 1000 ->
        exit(timeout_result_missing)
    end.

registered_name_send() ->
    Name = receive_matrix_registered,
    true = register(Name, self()),
    try
        Name ! {registered_send, Name, 17},
        receive
            {registered_send, Name, Value} ->
                Value
        after 1000 ->
            exit(registered_send_timeout)
        end
    after
        case whereis(Name) of
            undefined ->
                ok;
            _ ->
                unregister(Name)
        end
    end.

spawn3_roundtrip(Parent) ->
    Pid = spawn(?MODULE, spawn3_worker, [Parent]),
    receive
        {spawn3_ready, Pid} ->
            ok
    after 1000 ->
        exit(spawn3_ready_timeout)
    end,
    Pid ! {spawn3_request, Parent, 23},
    receive
        {spawn3_result, Pid, Value} ->
            Value
    after 1000 ->
        exit(spawn3_result_timeout)
    end.

spawn3_worker(Parent) ->
    Parent ! {spawn3_ready, self()},
    receive
        {spawn3_request, Parent, Value} ->
            Parent ! {spawn3_result, self(), Value + 1}
    after 1000 ->
        exit(spawn3_request_timeout)
    end.

spawn_link_cleanup(Parent) ->
    OldTrap = process_flag(trap_exit, true),
    Pid = spawn_link(?MODULE, linked_worker, [Parent]),
    try
        receive
            {linked_worker_done, Pid, normal} ->
                ok
        after 1000 ->
            exit(linked_worker_timeout)
        end,
        receive
            {'EXIT', Pid, Reason} ->
                Reason
        after 1000 ->
            exit(linked_exit_timeout)
        end
    after
        process_flag(trap_exit, OldTrap)
    end.

linked_worker(Parent) ->
    Parent ! {linked_worker_done, self(), normal},
    ok.

spawn_monitor_down(Parent) ->
    {Pid, Ref} = spawn_monitor(?MODULE, monitored_worker, [Parent]),
    receive
        {monitor_worker_done, Pid, normal} ->
            ok
    after 1000 ->
        exit(monitor_worker_timeout)
    end,
    receive
        {'DOWN', Ref, process, Pid, Reason} ->
            Reason
    after 1000 ->
        exit(monitor_down_timeout)
    end.

monitored_worker(Parent) ->
    Parent ! {monitor_worker_done, self(), normal},
    ok.

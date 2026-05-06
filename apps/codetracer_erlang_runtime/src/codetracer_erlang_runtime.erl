-module(codetracer_erlang_runtime).

-export([start_session/1, step/1, stop_session/1]).

start_session(Options) when is_list(Options) ->
    case application:ensure_all_started(codetracer_erlang_runtime) of
        {ok, _Started} ->
            codetracer_session:start_session(Options);
        {error, {already_started, codetracer_erlang_runtime}} ->
            codetracer_session:start_session(Options);
        {error, Reason} ->
            {error, Reason}
    end.

stop_session(Reason) ->
    codetracer_session:stop_session(Reason).

step(LocationId) when is_integer(LocationId) ->
    codetracer_session:step(LocationId).

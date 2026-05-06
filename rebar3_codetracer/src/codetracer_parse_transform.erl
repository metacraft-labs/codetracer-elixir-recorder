-module(codetracer_parse_transform).

-export([parse_transform/2]).

parse_transform(Forms, _Options) ->
    Module = module_name(Forms),
    write_marker(Module),
    [transform_form(Form) || Form <- Forms].

module_name(Forms) ->
    case [Module || {attribute, _Anno, module, Module} <- Forms] of
        [Module | _] -> Module;
        [] -> unknown
    end.

write_marker(Module) ->
    case os:getenv("CODETRACER_REBAR3_PARSE_TRANSFORM_MARKER_DIR") of
        false ->
            ok;
        Dir ->
            ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
            Path = filename:join(Dir, atom_to_list(Module) ++ ".marker"),
            file:write_file(Path, atom_to_list(Module) ++ "\n")
    end.

transform_form({function, Anno, Name, Arity, Clauses}) ->
    {function, Anno, Name, Arity, [transform_clause(Clause) || Clause <- Clauses]};
transform_form(Form) ->
    Form.

transform_clause({clause, Anno, Patterns, Guards, Body}) ->
    {clause, Anno, Patterns, Guards, [marker_call(Anno) | Body]}.

marker_call(Anno0) ->
    Anno = erl_anno:set_generated(true, Anno0),
    {call, Anno,
     {remote, Anno, {atom, Anno, erlang}, {atom, Anno, put}},
     [{atom, Anno, codetracer_parse_transform_compat}, {atom, Anno, true}]}.

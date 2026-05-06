-module(codetracer_forms).

-export([instrument_file/4]).

instrument_file(SourcePath, OutDir, LocationsPath, DumpPath) ->
    try
        ok = filelib:ensure_dir(filename:join(OutDir, "dummy.beam")),
        ok = filelib:ensure_dir(LocationsPath),
        ok = filelib:ensure_dir(DumpPath),
        {ok, Forms0} = parse_forms(SourcePath),
        Module = module_name(Forms0),
        {Forms, Locations0} = instrument_forms(Forms0, Module, SourcePath),
        Locations = dedup_locations(Locations0),
        ok = write_locations(LocationsPath, Module, SourcePath, Locations),
        ok = write_forms_dump(DumpPath, Forms),
        case compile:noenv_forms(Forms, [debug_info, return_errors, return_warnings, {outdir, OutDir}]) of
            {ok, _Module} ->
                ok;
            {ok, _Module, _Warnings} ->
                ok;
            {ok, CompiledModule, Beam} when is_binary(Beam) ->
                write_beam(OutDir, CompiledModule, Beam);
            {ok, CompiledModule, Beam, _Warnings} when is_binary(Beam) ->
                write_beam(OutDir, CompiledModule, Beam);
            {error, Errors, Warnings} ->
                {error, {compile_failed, Errors, Warnings}};
            Other ->
                {error, {compile_failed, Other}}
        end
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.

write_beam(OutDir, Module, Beam) ->
    file:write_file(filename:join(OutDir, atom_to_list(Module) ++ ".beam"), Beam).

parse_forms(SourcePath) ->
    {ok, Epp} = epp:open([{name, SourcePath}, {includes, []}, {macros, []}, {location, {1, 1}}]),
    parse_forms(Epp, []).

parse_forms(Epp, Acc) ->
    case epp:scan_erl_form(Epp) of
        {ok, Tokens} ->
            _Locations = [erl_scan:location(Token) || Token <- Tokens],
            case erl_parse:parse_form(Tokens) of
                {ok, Form} ->
                    parse_forms(Epp, [Form | Acc]);
                {error, Error} ->
                    epp:close(Epp),
                    {error, Error}
            end;
        {warning, _Warning} ->
            parse_forms(Epp, Acc);
        {eof, _Line} ->
            epp:close(Epp),
            {ok, lists:reverse(Acc)};
        {error, Error} ->
            epp:close(Epp),
            {error, Error}
    end.

module_name(Forms) ->
    case [Module || {attribute, _Anno, module, Module} <- Forms] of
        [Module | _] -> atom_to_list(Module);
        [] -> "unknown"
    end.

instrument_forms(Forms, Module, SourcePath) ->
    {Instrumented, State} =
        lists:mapfoldl(
            fun(Form, State0) -> instrument_form(Form, Module, SourcePath, State0) end,
            #{locations => []},
            Forms
        ),
    {Instrumented, maps:get(locations, State)}.

instrument_form({function, Anno, Name, Arity, Clauses}, Module, SourcePath, State0) ->
    {NewClauses, State} =
        lists:mapfoldl(
            fun(Clause, State1) ->
                instrument_clause(Clause, Module, SourcePath, Name, Arity, State1)
            end,
            State0,
            Clauses
        ),
    {{function, Anno, Name, Arity, NewClauses}, State};
instrument_form(Form, _Module, _SourcePath, State) ->
    {Form, State}.

instrument_clause({clause, Anno, Patterns, Guards, Body}, Module, SourcePath, Name, Arity, State0) ->
    {NewBody, State} = instrument_body(Body, Module, SourcePath, Name, Arity, undefined, State0),
    {{clause, Anno, Patterns, Guards, NewBody}, State}.

instrument_body([], _Module, _SourcePath, _Name, _Arity, _LastLocation, State) ->
    {[], State};
instrument_body([Expr | Rest], Module, SourcePath, Name, Arity, LastLocation, State0) ->
    {NewExpr, State1} = instrument_expr(Expr, Module, SourcePath, Name, Arity, State0),
    case expr_location(Expr) of
        undefined ->
            {NewRest, State} = instrument_body(Rest, Module, SourcePath, Name, Arity, LastLocation, State1),
            {[NewExpr | NewRest], State};
        Location when Location =:= LastLocation ->
            {NewRest, State} = instrument_body(Rest, Module, SourcePath, Name, Arity, LastLocation, State1),
            {[NewExpr | NewRest], State};
        Location ->
            LocationId = location_id(Module, Name, Arity, Location),
            Step = step_expr(expr_anno(Expr), LocationId),
            State2 = remember_location(Module, SourcePath, LocationId, Location, expr_anno(Expr), State1),
            {NewRest, State} = instrument_body(Rest, Module, SourcePath, Name, Arity, Location, State2),
            {[Step, NewExpr | NewRest], State}
    end.

instrument_expr({'case', Anno, Expr, Clauses}, Module, SourcePath, Name, Arity, State0) ->
    {NewClauses, State} =
        lists:mapfoldl(
            fun(Clause, State1) ->
                instrument_clause(Clause, Module, SourcePath, Name, Arity, State1)
            end,
            State0,
            Clauses
        ),
    {{'case', Anno, Expr, NewClauses}, State};
instrument_expr({'if', Anno, Clauses}, Module, SourcePath, Name, Arity, State0) ->
    {NewClauses, State} =
        lists:mapfoldl(
            fun(Clause, State1) ->
                instrument_clause(Clause, Module, SourcePath, Name, Arity, State1)
            end,
            State0,
            Clauses
        ),
    {{'if', Anno, NewClauses}, State};
instrument_expr({'receive', Anno, Clauses}, Module, SourcePath, Name, Arity, State0) ->
    {NewClauses, State} =
        lists:mapfoldl(
            fun(Clause, State1) ->
                instrument_clause(Clause, Module, SourcePath, Name, Arity, State1)
            end,
            State0,
            Clauses
        ),
    {{'receive', Anno, NewClauses}, State};
instrument_expr({'receive', Anno, Clauses, Timeout, AfterBody}, Module, SourcePath, Name, Arity, State0) ->
    {NewClauses, State1} =
        lists:mapfoldl(
            fun(Clause, State2) ->
                instrument_clause(Clause, Module, SourcePath, Name, Arity, State2)
            end,
            State0,
            Clauses
        ),
    {NewAfterBody, State} = instrument_body(AfterBody, Module, SourcePath, Name, Arity, undefined, State1),
    {{'receive', Anno, NewClauses, Timeout, NewAfterBody}, State};
instrument_expr({'try', Anno, Body, Clauses, CatchClauses, AfterBody}, Module, SourcePath, Name, Arity, State0) ->
    {NewBody, State1} = instrument_body(Body, Module, SourcePath, Name, Arity, undefined, State0),
    {NewClauses, State2} =
        lists:mapfoldl(
            fun(Clause, State3) ->
                instrument_clause(Clause, Module, SourcePath, Name, Arity, State3)
            end,
            State1,
            Clauses
        ),
    {NewCatchClauses, State3} =
        lists:mapfoldl(
            fun(Clause, State4) ->
                instrument_clause(Clause, Module, SourcePath, Name, Arity, State4)
            end,
            State2,
            CatchClauses
        ),
    {NewAfterBody, State} = instrument_body(AfterBody, Module, SourcePath, Name, Arity, undefined, State3),
    {{'try', Anno, NewBody, NewClauses, NewCatchClauses, NewAfterBody}, State};
instrument_expr({block, Anno, Body}, Module, SourcePath, Name, Arity, State0) ->
    {NewBody, State} = instrument_body(Body, Module, SourcePath, Name, Arity, undefined, State0),
    {{block, Anno, NewBody}, State};
instrument_expr(Expr, _Module, _SourcePath, _Name, _Arity, State) ->
    {Expr, State}.

expr_anno({Tag, Anno, _}) when is_atom(Tag) ->
    Anno;
expr_anno({Tag, Anno, _, _}) when is_atom(Tag) ->
    Anno;
expr_anno({Tag, Anno, _, _, _}) when is_atom(Tag) ->
    Anno;
expr_anno({Tag, Anno, _, _, _, _}) when is_atom(Tag) ->
    Anno;
expr_anno({Tag, Anno, _, _, _, _, _}) when is_atom(Tag) ->
    Anno;
expr_anno(_) ->
    erl_anno:new(0).

expr_location(Expr) ->
    Anno = expr_anno(Expr),
    case erl_anno:line(Anno) of
        undefined ->
            undefined;
        0 ->
            undefined;
        Line ->
            {Line, erl_anno:column(Anno)}
    end.

step_expr(Anno0, LocationId) ->
    Anno = erl_anno:set_generated(true, Anno0),
    {call, Anno,
        {remote, Anno,
            {atom, Anno, codetracer_erlang_runtime},
            {atom, Anno, step}},
        [{integer, Anno, LocationId}]}.

remember_location(Module, SourcePath, LocationId, {Line, Column}, Anno, State) ->
    Location = #{
        id => LocationId,
        module => Module,
        source_path => filename:absname(SourcePath),
        line => Line,
        column => Column,
        file => anno_file(Anno, SourcePath),
        generated => erl_anno:generated(Anno)
    },
    State#{locations := [Location | maps:get(locations, State)]}.

anno_file(Anno, SourcePath) ->
    case erl_anno:file(Anno) of
        undefined -> filename:absname(SourcePath);
        File -> File
    end.

location_id(Module, Name, Arity, {Line, Column}) ->
    Text = lists:flatten(io_lib:format("~s:~p/~p:~p:~p", [Module, Name, Arity, Line, Column])),
    fnv1a(Text).

fnv1a(Text) ->
    Hash = lists:foldl(
        fun(Char, Acc) ->
            ((Acc bxor Char) * 16777619) band 16#ffffffff
        end,
        2166136261,
        Text
    ),
    case Hash of
        0 -> 1;
        _ -> Hash
    end.

dedup_locations(Locations) ->
    {_, Reversed} =
        lists:foldl(
            fun(Location, {Seen, Acc}) ->
                Id = maps:get(id, Location),
                case maps:is_key(Id, Seen) of
                    true -> {Seen, Acc};
                    false -> {maps:put(Id, true, Seen), [Location | Acc]}
                end
            end,
            {#{}, []},
            Locations
        ),
    lists:reverse(Reversed).

write_locations(Path, Module, SourcePath, Locations) ->
    Json = [
        "{\"schema\":\"codetracer.beam.step-locations.v1\",",
        "\"module\":", json_string(Module), ",",
        "\"source_path\":", json_string(filename:absname(SourcePath)), ",",
        "\"locations\":[",
        join_json([location_json(Location) || Location <- Locations]),
        "]}\n"
    ],
    file:write_file(Path, Json).

location_json(Location) ->
    [
        "{\"id\":", integer_to_list(maps:get(id, Location)), ",",
        "\"module\":", json_string(maps:get(module, Location)), ",",
        "\"source_path\":", json_string(maps:get(source_path, Location)), ",",
        "\"file\":", json_string(maps:get(file, Location)), ",",
        "\"line\":", integer_to_list(maps:get(line, Location)), ",",
        "\"column\":", json_nullable_integer(maps:get(column, Location)), ",",
        "\"generated\":", json_boolean(maps:get(generated, Location)),
        "}"
    ].

write_forms_dump(Path, Forms) ->
    Text = [
        "%% codetracer transformed forms dump format: erl_pp:form/1 pretty-printed Erlang source\n",
        [erl_pp:form(Form) || Form <- Forms]
    ],
    file:write_file(Path, Text).

join_json([]) ->
    "";
join_json([Value]) ->
    Value;
join_json([Value | Rest]) ->
    [Value, ",", join_json(Rest)].

json_nullable_integer(undefined) ->
    "null";
json_nullable_integer(Value) ->
    integer_to_list(Value).

json_boolean(true) ->
    "true";
json_boolean(false) ->
    "false".

json_string(Value) when is_list(Value) ->
    [$", escape_json(Value), $"];
json_string(Value) when is_atom(Value) ->
    json_string(atom_to_list(Value)).

escape_json([]) ->
    [];
escape_json([$" | Rest]) ->
    [$\\, $" | escape_json(Rest)];
escape_json([$\\ | Rest]) ->
    [$\\, $\\ | escape_json(Rest)];
escape_json([$\n | Rest]) ->
    [$\\, $n | escape_json(Rest)];
escape_json([$\r | Rest]) ->
    [$\\, $r | escape_json(Rest)];
escape_json([$\t | Rest]) ->
    [$\\, $t | escape_json(Rest)];
escape_json([Char | Rest]) ->
    [Char | escape_json(Rest)].

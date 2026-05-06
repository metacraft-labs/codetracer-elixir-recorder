-module(codetracer_forms).

-export([instrument_file/4]).

instrument_file(SourcePath, OutDir, LocationsPath, DumpPath) ->
    try
        ok = filelib:ensure_dir(filename:join(OutDir, "dummy.beam")),
        ok = filelib:ensure_dir(LocationsPath),
        ok = filelib:ensure_dir(DumpPath),
        {ok, Forms0} = parse_forms(SourcePath),
        Module = module_name(Forms0),
        {Forms, Locations0, VariableSlots0} = instrument_forms(Forms0, Module, SourcePath),
        Locations = dedup_locations(Locations0),
        VariableSlots = dedup_variable_slots(VariableSlots0),
        ok = write_locations(LocationsPath, Module, SourcePath, Locations, VariableSlots),
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
            #{locations => [], variable_slot_templates => []},
            Forms
        ),
    {Instrumented, maps:get(locations, State), maps:get(variable_slot_templates, State)}.

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
    FunctionKey = function_key(Module, Name, Arity),
    {EntryBindings, Visible0, State1} =
        bindings_for_patterns(Patterns, FunctionKey, "clause_entry", State0),
    {NewBody0, _Visible, State2} =
        instrument_body(Body, Module, SourcePath, Name, Arity, undefined, Visible0, State1),
    NewBody = insert_entry_bindings(NewBody0, EntryBindings, Anno),
    {{clause, Anno, Patterns, Guards, NewBody}, State2}.

instrument_body([], _Module, _SourcePath, _Name, _Arity, _LastLocation, Visible, State) ->
    {[], Visible, State};
instrument_body([Expr | Rest], Module, SourcePath, Name, Arity, LastLocation, Visible0, State0) ->
    NonTail = Rest =/= [],
    {NewExpr, Visible1, State1} =
        instrument_body_expr(Expr, Module, SourcePath, Name, Arity, NonTail, Visible0, State0),
    case expr_location(Expr) of
        undefined ->
            {NewRest, Visible, State} =
                instrument_body(Rest, Module, SourcePath, Name, Arity, LastLocation, Visible1, State1),
            {[NewExpr | NewRest], Visible, State};
        Location when Location =:= LastLocation ->
            {NewRest, Visible, State} =
                instrument_body(Rest, Module, SourcePath, Name, Arity, LastLocation, Visible1, State1),
            {[NewExpr | NewRest], Visible, State};
        Location ->
            LocationId = location_id(Module, Name, Arity, Location),
            Step = step_expr(expr_anno(Expr), LocationId),
            State2 = remember_location(Module, SourcePath, LocationId, Location, expr_anno(Expr), State1),
            {NewRest, Visible, State} =
                instrument_body(Rest, Module, SourcePath, Name, Arity, Location, Visible1, State2),
            {[Step, NewExpr | NewRest], Visible, State}
    end.

instrument_body_expr({match, Anno, Pattern, Rhs}, Module, SourcePath, Name, Arity, true, Visible0, State0) ->
    {NewRhs, State1} = instrument_expr(Rhs, Module, SourcePath, Name, Arity, State0),
    NewVariables = pattern_variables(Pattern, Visible0),
    case NewVariables of
        [] ->
            {{match, Anno, Pattern, NewRhs}, Visible0, State1};
        _ ->
            FunctionKey = function_key(Module, Name, Arity),
            {Bindings, Visible, State} =
                bindings_for_variables(NewVariables, FunctionKey, "match_expression", Visible0, State1),
            Temp = list_to_atom("CodetracerMatchRhs" ++ integer_to_list(fnv1a(lists:flatten(io_lib:format("~p", [Anno]))))),
            GenAnno = erl_anno:set_generated(true, Anno),
            TempVar = {var, GenAnno, Temp},
            BindExprs = binding_exprs(Bindings, GenAnno),
            Block = {block, GenAnno, [
                {match, GenAnno, TempVar, NewRhs},
                {match, Anno, Pattern, TempVar}
            ] ++ BindExprs ++ [TempVar]},
            {Block, Visible, State}
    end;
instrument_body_expr(Expr, Module, SourcePath, Name, Arity, _NonTail, Visible, State0) ->
    {NewExpr, State} = instrument_expr(Expr, Module, SourcePath, Name, Arity, State0),
    {NewExpr, Visible, State}.

instrument_expr({'case', Anno, Expr, Clauses}, Module, SourcePath, Name, Arity, State0) ->
    {NewExpr, State1} = instrument_expr(Expr, Module, SourcePath, Name, Arity, State0),
    {NewClauses, State} =
        lists:mapfoldl(
            fun(Clause, State1) ->
                instrument_clause(Clause, Module, SourcePath, Name, Arity, State1)
            end,
            State1,
            Clauses
        ),
    {{'case', Anno, NewExpr, NewClauses}, State};
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
    {NewAfterBody, _Visible, State} =
        instrument_body(AfterBody, Module, SourcePath, Name, Arity, undefined, [], State1),
    {{'receive', Anno, NewClauses, Timeout, NewAfterBody}, State};
instrument_expr({'try', Anno, Body, Clauses, CatchClauses, AfterBody}, Module, SourcePath, Name, Arity, State0) ->
    {NewBody, _BodyVisible, State1} =
        instrument_body(Body, Module, SourcePath, Name, Arity, undefined, [], State0),
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
    {NewAfterBody, _AfterVisible, State} =
        instrument_body(AfterBody, Module, SourcePath, Name, Arity, undefined, [], State3),
    {{'try', Anno, NewBody, NewClauses, NewCatchClauses, NewAfterBody}, State};
instrument_expr({block, Anno, Body}, Module, SourcePath, Name, Arity, State0) ->
    {NewBody, _Visible, State} =
        instrument_body(Body, Module, SourcePath, Name, Arity, undefined, [], State0),
    {{block, Anno, NewBody}, State};
instrument_expr({'fun', Anno, {clauses, Clauses}}, Module, SourcePath, Name, Arity, State0) ->
    {NewClauses, State} =
        lists:mapfoldl(
            fun(Clause, State1) ->
                instrument_clause(Clause, Module, SourcePath, Name, Arity, State1)
            end,
            State0,
            Clauses
        ),
    {{'fun', Anno, {clauses, NewClauses}}, State};
instrument_expr(Expr, _Module, _SourcePath, _Name, _Arity, State) ->
    {Expr, State}.

insert_entry_bindings(Body, [], _Anno) ->
    Body;
insert_entry_bindings([Step = {call, _, {remote, _, {atom, _, codetracer_erlang_runtime}, {atom, _, step}}, _} | Rest], Bindings, Anno) ->
    [Step | binding_exprs(Bindings, Anno) ++ Rest];
insert_entry_bindings(Body, Bindings, Anno) ->
    binding_exprs(Bindings, Anno) ++ Body.

binding_exprs([], _Anno) ->
    [];
binding_exprs(Bindings, Anno0) ->
    Anno = erl_anno:set_generated(true, Anno0),
    [{call, Anno,
        {remote, Anno,
            {atom, Anno, codetracer_erlang_runtime},
            {atom, Anno, bind_many}},
        [list_expr([binding_tuple(Binding, Anno) || Binding <- Bindings], Anno)]}].

binding_tuple(#{slot := Slot, name := Name, var := Var}, Anno) ->
    {tuple, Anno, [
        {integer, Anno, Slot},
        {string, Anno, Name},
        {var, Anno, Var}
    ]}.

bindings_for_patterns(Patterns, FunctionKey, Source, State0) ->
    Variables = pattern_variables(Patterns, []),
    {Bindings, Visible, State} = bindings_for_variables(Variables, FunctionKey, Source, [], State0),
    {Bindings, Visible, State}.

bindings_for_variables(Variables, FunctionKey, Source, Visible0, State0) ->
    {Bindings, Visible, State} = lists:foldl(
        fun(Var, {Bindings, Visible, State}) ->
            Name = atom_to_list(Var),
            Slot = variable_slot(FunctionKey, Source, Name, length(Bindings)),
            Binding = #{slot => Slot, name => Name, var => Var},
            SlotTemplate = #{
                function_key => FunctionKey,
                slot => Slot,
                name => Name,
                source => Source
            },
            {[Binding | Bindings], add_visible(Var, Visible), remember_variable_slot(SlotTemplate, State)}
        end,
        {[], Visible0, State0},
        Variables
    ),
    {lists:reverse(Bindings), Visible, State}.

list_expr([], Anno) ->
    {nil, Anno};
list_expr([Head | Rest], Anno) ->
    {cons, Anno, Head, list_expr(Rest, Anno)}.

pattern_variables(Pattern, Visible) when is_tuple(Pattern) ->
    case Pattern of
        {var, _Anno, '_'} ->
            [];
        {var, _Anno, Var} ->
            case lists:member(Var, Visible) of
                true -> [];
                false -> [Var]
            end;
        _ ->
            pattern_variables(tuple_to_list(Pattern), Visible)
    end;
pattern_variables(Patterns, Visible) when is_list(Patterns) ->
    {Variables, _Seen} =
        lists:foldl(
            fun(Pattern, {Vars, Seen}) ->
                New = pattern_variables(Pattern, Seen),
                {Vars ++ New, lists:foldl(fun add_visible/2, Seen, New)}
            end,
            {[], Visible},
            Patterns
        ),
    Variables;
pattern_variables(_Pattern, _Visible) ->
    [].

add_visible(Var, Visible) ->
    case lists:member(Var, Visible) of
        true -> Visible;
        false -> [Var | Visible]
    end.

function_key(Module, Name, Arity) ->
    lists:flatten(io_lib:format("~s.~p/~p", [Module, Name, Arity])).

variable_slot(FunctionKey, Source, Name, Index) ->
    fnv1a(lists:flatten(io_lib:format("~s:~s:~s:~p", [FunctionKey, Source, Name, Index]))).

remember_variable_slot(SlotTemplate, State) ->
    State#{variable_slot_templates := [SlotTemplate | maps:get(variable_slot_templates, State)]}.

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

write_locations(Path, Module, SourcePath, Locations, VariableSlots) ->
    Json = [
        "{\"schema\":\"codetracer.beam.step-locations.v1\",",
        "\"module\":", json_string(Module), ",",
        "\"source_path\":", json_string(filename:absname(SourcePath)), ",",
        "\"variable_slot_templates\":[",
        join_json([variable_slot_json(Slot) || Slot <- VariableSlots]),
        "],",
        "\"locations\":[",
        join_json([location_json(Location) || Location <- Locations]),
        "]}\n"
    ],
    file:write_file(Path, Json).

dedup_variable_slots(Slots) ->
    {_, Reversed} =
        lists:foldl(
            fun(Slot, {Seen, Acc}) ->
                Key = {maps:get(function_key, Slot), maps:get(slot, Slot)},
                case maps:is_key(Key, Seen) of
                    true -> {Seen, Acc};
                    false -> {maps:put(Key, true, Seen), [Slot | Acc]}
                end
            end,
            {#{}, []},
            Slots
        ),
    lists:reverse(Reversed).

variable_slot_json(Slot) ->
    [
        "{\"function_key\":", json_string(maps:get(function_key, Slot)), ",",
        "\"slot\":", integer_to_list(maps:get(slot, Slot)), ",",
        "\"name\":", json_string(maps:get(name, Slot)), ",",
        "\"source\":", json_string(maps:get(source, Slot)),
        "}"
    ].

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

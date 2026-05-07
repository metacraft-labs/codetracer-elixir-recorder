# Rebar3 Integration

The Rebar3 integration is shipped as the `rebar3_codetracer` OTP plugin app.
The provider command is `codetracer`, so projects run it through a dedicated
profile:

```erlang
{profiles, [
  {codetrace, [
    {plugins, [rebar3_codetracer]},
    {erl_opts, [debug_info]},
    {codetracer, [
      {out_dir, "ct-traces"},
      {root_mfa, "my_app:main/0"},
      {eval, "my_app:main()."}
    ]}
  ]}
]}.
```

Run with:

```sh
rebar3 as codetrace codetracer
```

Provider mode is the default. It compiles normal Rebar3 artifacts under the
`codetrace` profile, creates instrumented BEAMs and recorder metadata under
`_build/codetrace/codetracer`, and runs a real `rebar3 as codetrace shell`
through `codetracer-beam-recorder record`. Default profile artifacts are not
mutated.

Parse-transform compatibility mode is Erlang-only and intentionally narrow:
add `{parse_transform, codetracer_parse_transform}` to the `codetrace` profile
`erl_opts` and set `{parse_transform, true}` in the `codetracer` config.

Public distribution decision for M13: publish the Rebar3 package as
`rebar3_codetracer` on Hex, with OTP application `rebar3_codetracer` and
provider command `codetracer`. The recorder binary remains distributed as
`codetracer-beam-recorder`.

{
  description = "CodeTracer BEAM materialized trace recorder (Erlang and Elixir)";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      git-hooks,
      ...
    }:
    let
      cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
      mkBeamRecorderPackage =
        {
          pkgs,
        }:
        pkgs.rustPlatform.buildRustPackage {
          pname = "codetracer-beam-recorder";
          version = cargoToml.package.version;

          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
          nativeBuildInputs = with pkgs; [
            capnproto
            pkg-config
          ];
          buildInputs = with pkgs; [
            zstd
          ];

          meta = {
            description = "CodeTracer BEAM materialized trace recorder (Erlang and Elixir)";
            homepage = "https://github.com/metacraft-labs/codetracer-beam-recorder";
            license = pkgs.lib.licenses.mit;
            mainProgram = "codetracer-beam-recorder";
          };
        };
      # Deprecated alias retained for one release cycle so downstream consumers
      # that still reference the Elixir-only naming continue to work.
      mkElixirRecorderPackage = mkBeamRecorderPackage;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake.lib.mkBeamRecorderPackage = mkBeamRecorderPackage;
      # Deprecated: prefer mkBeamRecorderPackage. Retained for one release cycle.
      flake.lib.mkElixirRecorderPackage = mkElixirRecorderPackage;

      perSystem =
        {
          self',
          pkgs,
          system,
          ...
        }:
        let
          preCommit = self.checks.${system}.pre-commit-check;
        in
        {
          checks.pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
                extraPackages = with pkgs; [
                  cargo
                  clippy
                  just
                  nixfmt
                  rebar3
                  rustc
                  rustfmt
                  shellcheck
                  shfmt
                ];
              };
              check-added-large-files.enable = true;
              check-merge-conflicts.enable = true;
            };
          };

          devShells.default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                cargo
                capnproto
                clippy
                elixir
                erlang
                just
                jq
                nixfmt
                pkg-config
                prek
                rebar3
                rustc
                rustfmt
                shellcheck
                shfmt
                zstd
              ]
              ++ preCommit.enabledPackages;

            shellHook = preCommit.shellHook;
          };

          packages.codetracer-beam-recorder = mkBeamRecorderPackage { inherit pkgs; };
          # Deprecated alias retained for one release cycle.
          packages.codetracer-elixir-recorder = self'.packages.codetracer-beam-recorder;
          packages.default = self'.packages.codetracer-beam-recorder;
        };
    };
}

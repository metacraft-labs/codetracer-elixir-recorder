{
  description = "CodeTracer Elixir and Erlang materialized trace recorder";

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
      mkElixirRecorderPackage =
        {
          pkgs,
        }:
        pkgs.rustPlatform.buildRustPackage {
          pname = "codetracer-elixir-recorder";
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
            description = "CodeTracer Elixir and Erlang materialized trace recorder";
            homepage = "https://github.com/metacraft-labs/codetracer-elixir-recorder";
            license = pkgs.lib.licenses.mit;
            mainProgram = "codetracer-elixir-recorder";
          };
        };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

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

          packages.codetracer-elixir-recorder = mkElixirRecorderPackage { inherit pkgs; };
          packages.default = self'.packages.codetracer-elixir-recorder;
        };
    };
}

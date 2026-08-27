{
  description = "diaryx-org's shared toolchain: one Zig pin, one Rust pin, and the dev shells every repository builds on";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # No flake-utils. Every other flake in the org uses it, and this one cannot:
  # `eachDefaultSystem` puts *everything* it wraps under a system attribute, and
  # `versions` has to stay readable without one so that a workflow can ask for it
  # with `nix eval --raw github:diaryx-org/nix#versions.zig`. Twelve lines of
  # `genAttrs` is the price of that, and it removes an input besides.
  outputs = { self, nixpkgs, rust-overlay, zig-overlay }:
    let
      versions = builtins.fromTOML (builtins.readFile ./versions.toml);

      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      };

      # The one Rust toolchain, at the one version. `default` is rust-overlay's
      # profile — cargo, rustc, rust-std, clippy, rustfmt — and the two
      # extensions added here are the ones an editor needs and a build does not,
      # which is why they belong in a dev shell rather than in a derivation.
      rustFor = system: { targets ? [ ], extensions ? [ ] }:
        (pkgsFor system).rust-bin.stable.${versions.rust}.default.override {
          inherit targets;
          extensions = [ "rust-src" "rust-analyzer" ] ++ extensions;
        };

      zigFor = system: zig-overlay.packages.${system}.${versions.zig};

      # Every shell in the org, from one builder.
      #
      # `packages` is the escape hatch, and it takes derivations rather than
      # names: a repository resolves them from its own nixpkgs, which is a second
      # nixpkgs in the closure and is fine. What it must not do is grow an
      # argument here for every tool one repository wants — the point of this
      # file is the two versions, and a builder that accumulates `withLlvmCov`
      # flags is a build system.
      mkShell = system: {
        rust ? false,
        zig ? false,
        targets ? [ ],
        extensions ? [ ],
        packages ? [ ],
        ...
      }@args:
        let
          pkgs = pkgsFor system;
        in
        pkgs.mkShell ((builtins.removeAttrs args [ "rust" "zig" "targets" "extensions" "packages" ]) // {
          nativeBuildInputs =
            nixpkgs.lib.optional rust (rustFor system { inherit targets extensions; })
            ++ nixpkgs.lib.optional zig (zigFor system)
            # In every shell, because every repository's changelog is generated
            # and `dx changelog --check` is what CI and the release both call.
            # It is small, and a repo that discovers it is missing discovers it
            # halfway through cutting a release.
            ++ [ pkgs.git-cliff ]
            ++ packages;

          # Zig writes to a global cache that defaults under $HOME, which is the
          # one thing a Zig build needs and a Nix shell does not provide a
          # sensible default for. Kept beside the checkout rather than in $HOME
          # so that `rm -rf .zig-cache` means what it says.
          shellHook = nixpkgs.lib.optionalString zig ''
            export ZIG_GLOBAL_CACHE_DIR="''${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-cache}"
          '';
        });
    in
    {
      # System-independent on purpose: this is data, and a workflow reads it
      # without evaluating a package.
      inherit versions;

      lib = forAllSystems (system: {
        mkShell = mkShell system;
        rust = rustFor system;
        zig = zigFor system;
      });

      # The three shells that need no arguments, for the repositories that need
      # nothing else. `rust-zig` is prov's shape: a Cargo workspace whose build
      # scripts run `zig build`.
      devShells = forAllSystems (system: rec {
        rust = mkShell system { rust = true; };
        zig = mkShell system { zig = true; };
        rust-zig = mkShell system { rust = true; zig = true; };
        default = rust;
      });

      # `nix flake check` builds all three on the current system, so a bump to
      # either version fails here rather than in the first repository to pull it.
      checks = forAllSystems (system:
        nixpkgs.lib.mapAttrs' (name: shell: nixpkgs.lib.nameValuePair "devShell-${name}" shell)
          (builtins.removeAttrs self.devShells.${system} [ "default" ]));
    };
}

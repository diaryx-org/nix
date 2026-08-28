# nix

diaryx-org's shared toolchain: one Zig pin, one Rust pin, and the dev shells
every repository builds on.

```nix
inputs.diaryx-nix.url = "github:diaryx-org/nix";
inputs.diaryx-nix.inputs.nixpkgs.follows = "nixpkgs";

devShells.default = diaryx-nix.devShells.${system}.rust-zig;
```

## Why

Zig `0.16.0` was written out eleven times — in three `flake.nix` files and in
eight workflow steps — and Rust was pinned nowhere at all except `leaf`, which
meant thirty-six CI jobs asking for `stable` and getting whatever it was that
morning.

Eleven copies of a version is eleven chances to bump ten of them. That is not a
tidiness problem here, because these versions are not independent: `prov` is a
Cargo workspace whose `fig` and `twig-doc` dependencies have build scripts that
shell out to `zig build`. A Zig bump in `fig` is a Zig bump in `prov` whether or
not anyone edits a line in `prov` — and the way that failure arrives is a build
error in a repository nobody changed.

So the versions live in one file, and everything else reads it.

## The versions

`versions.toml`. Two lines and the reasons for them:

| | | why this one |
|---|---|---|
| `zig` | `0.16.0` | what `fig` and `twig` are written against; pinned exactly, because Zig's pre-1.0 releases break the language and not just the standard library |
| `rust` | `1.95.0` | `leaf` sets the floor — gpui, pulled from the Zed monorepo by `leaf-gui`, uses library features stabilised in 1.95, and Zed pins that exact channel. Every crate's own `rust-version` is well below it, so one toolchain serves the org |

The two are not the same kind of pin, and it matters. **Zig has to match
exactly**: `prov` builds `fig` and `twig-doc` through their build scripts, and
Zig's pre-1.0 releases break the language, so a repository on a different
version does not compile. **Rust is a dev-shell pin only** — CI deliberately runs
`dtolnay/rust-toolchain@stable` in thirty-six jobs, because that is how a stable
release that breaks something gets found the week it lands. Those two numbers
drifting apart is the arrangement working. Where a floor has to hold, the repo
checks it directly; `diaryx` has `cargo xtask msrv`.

Bumping one is a commit here and a `nix flake update diaryx-nix` in each
repository that consumes it. The lock file in each repo is what makes arriving at
a new toolchain a decision rather than a surprise — this repository moving does
not move anything else until someone says so.

## The shells

Three that take no arguments:

| | |
|---|---|
| `devShells.${system}.rust` | the toolchain at `versions.rust`, with `rust-src` and `rust-analyzer` |
| `devShells.${system}.zig` | Zig at `versions.zig` |
| `devShells.${system}.rust-zig` | both — `prov`'s shape, a Cargo workspace whose build scripts run `zig build` |

`git-cliff` is in all three, because every repository's changelog has a generated
region and `dx changelog --check` is what both CI and the release call. A repo
that discovers it is missing discovers it halfway through cutting a release.

For anything else, `lib.${system}.mkShell` takes the same two flags plus
`packages`, `targets`, `extensions`, and `rustVersion`, and passes the rest
through to `pkgs.mkShell`:

```nix
devShells.default = diaryx-nix.lib.${system}.mkShell {
  rust = true;
  targets = [ "wasm32-unknown-unknown" ];
  packages = [ pkgs.cargo-llvm-cov pkgs.binaryen ];
};
```

`rustVersion` exists for the repository that will eventually need it. `1.95.0` is
the number that works everywhere — above every crate's MSRV in the org, and equal
to the channel Zed pins for gpui, which is `leaf`'s constraint. Those two being
the same number is luck, not design; when it runs out, the odd repository
overrides it rather than the other fifteen following it down. Note that current
stable is ahead of it, so a dev shell here is stricter than CI, which is the safe
direction: what compiles locally compiles there.

`packages` takes derivations rather than names, so they come from the consuming
repository's own nixpkgs. That is a second nixpkgs in the closure and it is
fine — `follows` collapses it if the versions agree, and a repository that wants
a tool this file has never heard of should not have to add an argument here to
get it.

## What does not consume this

`diaryx`. Its shell unsets `SDKROOT` and `DEVELOPER_DIR`, bypasses Nix's
cc-wrapper for the iOS targets because it injects macOS minimum-version flags,
puts the system directories back on `PATH` that `stdenv` removed, and builds two
tools from source. None of that generalises, and a `mkShell` stretched until it
did would be a build system. It reads `versions` and keeps its own shell.

The package derivations are not here either, in any repository. `fig`'s parses
`cli_version` out of `build.zig`; `twig`'s reads `build.zig.zon`; `prov`'s repacks
a Zig static archive with `libtool` because ld64 rejects Zig's alignment. Those
are genuinely per-repository, and sharing them would make each one worse.

## Reading the versions without Nix

The point of TOML. A workflow that needs the Zig pin and has no Nix:

```yaml
- uses: actions/checkout@v7
  with: { repository: diaryx-org/nix, path: .toolchain }
- id: v
  run: echo "zig=$(grep '^zig' .toolchain/versions.toml | cut -d'"' -f2)" >> "$GITHUB_OUTPUT"
- uses: mlugg/setup-zig@v2
  with: { version: "${{ steps.v.outputs.zig }}" }
```

On a machine that has Nix, `nix eval --raw github:diaryx-org/nix#versions.zig`
says the same thing. `versions` is deliberately not under a system attribute so
that this works — which is why this flake uses `genAttrs` where every other flake
in the org uses `flake-utils`, whose `eachDefaultSystem` would bury it.

## Checking it

```
nix flake check
```

Builds all three shells on the current system, so a version bump fails here
rather than in the first repository to pull it.

# Point `rustPlatform.importCargoLock` at static.crates.io on the CURRENT
# nixpkgs pin, without bumping the pin.
#
# Companion to fetch-cargo-vendor-user-agent.nix, which covers the other crate
# fetcher, `fetchCargoVendor`. crates.io answers 403 on
# `/api/v1/crates/*/download`; the pin predates the upstream move to the CDN
# (NixOS/nixpkgs#524979, backported to nixos-25.11), so `importCargoLock`
# consumers -- logos-rln-modules among them -- fail on any crate the binary
# cache misses.
#
# Mechanism: `import-cargo-lock.nix` takes `fetchurl` as a callPackage
# argument, so re-instantiating it with a wrapper that rewrites the API prefix
# leaves the pin's expression untouched. Rewriting at the fetcher rather than
# at the `registries` default keeps the generated `.cargo/config.toml`
# byte-identical; passing the CDN through `extraRegistries` instead would add a
# second `[source."...crates.io-index"]` block and move the vendor dir.
#
# The crate tarballs are fixed-output derivations keyed on the checksum from
# Cargo.lock, so the URL change moves no store path: the tarballs and the
# `cargo-vendor-dir` keep the paths they have today and nothing downstream
# rebuilds. Upstream relies on the same property.
#
# `fetchCrate` has the same stale default, but is deliberately left alone:
# overriding it perturbs derivations across the package set (the devShells
# move), and nothing here fetches through it. The pin bump in #5 covers it.
#
# The overlay is the identity on a pin that already fetches from the CDN, and
# fails at evaluation if the pin uses neither URL.
final: prev:
let
  inherit (prev) lib;

  apiPrefix = "https://crates.io/api/v1/crates";
  cdnPrefix = "https://static.crates.io/crates";

  importCargoLockFile = prev.path + "/pkgs/build-support/rust/import-cargo-lock.nix";
  importCargoLockSrc = builtins.readFile importCargoLockFile;

  alreadyFixed = lib.hasInfix cdnPrefix importCargoLockSrc;

  cdnFetchurl =
    args:
    prev.fetchurl (
      args
      // lib.optionalAttrs (args ? url) {
        url = builtins.replaceStrings [ apiPrefix ] [ cdnPrefix ] args.url;
      }
    );
in
if alreadyFixed then
  { }
else
  assert lib.assertMsg (lib.hasInfix apiPrefix importCargoLockSrc)
    "import-cargo-lock-static-crates-io overlay: ${toString importCargoLockFile} references neither ${apiPrefix} nor ${cdnPrefix}; the registry default moved and this overlay would silently do nothing";
  {
    makeRustPlatform =
      args:
      (prev.makeRustPlatform args).overrideScope (
        _: _rprev: {
          importCargoLock = final.callPackage importCargoLockFile { fetchurl = cdnFetchurl; };
        }
      );
  }

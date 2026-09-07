# Point `rustPlatform.importCargoLock` at static.crates.io on the current
# nixpkgs pin. crates.io 403s the pin's `/api/v1/crates/*/download` default;
# upstream moved to the CDN in NixOS/nixpkgs#524979, after this pin.
#
# Companion to fetch-cargo-vendor-user-agent.nix, which covers the other
# crate fetcher.
#
# `import-cargo-lock.nix` takes `fetchurl` as a callPackage argument, so
# re-instantiating it with a rewriting wrapper leaves the pin untouched.
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
    "import-cargo-lock-static-crates-io overlay: ${toString importCargoLockFile} references neither ${apiPrefix} nor ${cdnPrefix}; the registry default moved";
  {
    makeRustPlatform =
      args:
      (prev.makeRustPlatform args).overrideScope (
        _: _rprev: {
          importCargoLock = final.callPackage importCargoLockFile { fetchurl = cdnFetchurl; };
        }
      );
  }

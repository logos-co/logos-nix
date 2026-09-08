# Make `rustPlatform.fetchCargoVendor` send a User-Agent on the CURRENT
# nixpkgs pin, without bumping the pin.
#
# crates.io rejects requests carrying python-requests' default User-Agent
# with 403. The pin's `fetch-cargo-vendor-util.py` sets none, so every
# `*-vendor-staging` fixed-output derivation fails
# (logos-co/logos-module-builder#159). Upstream fixed this in
# NixOS/nixpkgs#512735 (merged 2026-04-26), which also moved crate downloads
# to the static.crates.io CDN; this overlay applies exactly those two
# network-facing lines to the pin's helper so behaviour matches what the
# eventual pin bump delivers.
#
# Mechanism: the helper is a `writePython3Bin` private to
# fetch-cargo-vendor.nix and cannot be overridden by name, so this wraps
# `makeRustPlatform` (the single constructor every `rustPlatform` -- the
# default rustc, rust-overlay toolchains via `pkgs.makeRustPlatform` -- goes
# through) and, inside the scope, re-points the `-vendor-staging` FOD at a
# patched copy of the helper. Only the FOD changes; its output hash is fixed,
# so consumer `cargoHash` values and the input-addressed `-vendor` derivation
# downstream are untouched. Nothing else in the package set is affected.
#
# Drift guard: on a pin whose helper already sets a User-Agent, this overlay
# is the identity; on a pin whose helper changed in any other way, it fails
# at evaluation rather than silently patching nothing.
final: prev:
let
  inherit (prev) lib;

  # Path concatenation, NOT "${prev.path}/...": interpolating `pkgs.path` into a
  # string makes `readFile` copy the whole nixpkgs tree in as a second store
  # path, which pure evaluation cannot do on a cold store.
  helperPath = prev.path + "/pkgs/build-support/rust/fetch-cargo-vendor-util.py";
  helperSrc = builtins.readFile helperPath;

  alreadyFixed = lib.hasInfix "User-Agent" helperSrc;

  # The two hunks of NixOS/nixpkgs#512735 that touch the network.
  edits = [
    {
      from = "    session = requests.Session()\n    session.mount('http://', HTTPAdapter(max_retries=retries))\n";
      to = "    session = requests.Session()\n    session.headers[\"User-Agent\"] = \"nixpkgs-fetchCargoVendor/2 (https://github.com/NixOS/nixpkgs)\"\n    session.mount('http://', HTTPAdapter(max_retries=retries))\n";
    }
    {
      from = "    return f\"https://crates.io/api/v1/crates/{pkg[\"name\"]}/{pkg[\"version\"]}/download\"\n";
      to = "    # Use static.crates.io (CDN) instead of crates.io/api to avoid the 1 req/sec\n    # rate limit on the API servers.\n    return f\"https://static.crates.io/crates/{pkg[\"name\"]}/{pkg[\"version\"]}/download\"\n";
    }
  ];

  patchedSrc = builtins.replaceStrings (map (e: e.from) edits) (map (e: e.to) edits) helperSrc;

  everyEditApplied = builtins.all (e: lib.hasInfix e.to patchedSrc) edits;

  patchedUtil =
    assert lib.assertMsg everyEditApplied
      "fetch-cargo-vendor-user-agent overlay: ${toString helperPath} no longer matches the hunks this overlay patches; drop the overlay if the pin already sends a User-Agent, otherwise update the hunks";
    # Built for the build platform, like the original (fetch-cargo-vendor.nix
    # is instantiated with `buildPackages.callPackage`).
    final.buildPackages.writers.writePython3Bin "fetch-cargo-vendor-util-ua" {
      libraries = [ final.buildPackages.python3Packages.requests ];
      flakeIgnore = [ "E501" ];
    } patchedSrc;

  originalCall = "fetch-cargo-vendor-util create-vendor-staging";
  patchedCall = "fetch-cargo-vendor-util-ua create-vendor-staging";

  patchVendorStaging = staging: staging.overrideAttrs (s:
    assert lib.assertMsg (lib.hasInfix originalCall s.buildPhase)
      "fetch-cargo-vendor-user-agent overlay: vendorStaging buildPhase no longer invokes `${originalCall}`";
    {
      nativeBuildInputs = [ patchedUtil ] ++ s.nativeBuildInputs;
      buildPhase = builtins.replaceStrings [ originalCall ] [ patchedCall ] s.buildPhase;
    });

  wrapFetchCargoVendor = fetchCargoVendor: args:
    let vendor = fetchCargoVendor args;
    in vendor.overrideAttrs (v: { vendorStaging = patchVendorStaging v.vendorStaging; });
in
if alreadyFixed then { } else {
  makeRustPlatform = args:
    (prev.makeRustPlatform args).overrideScope (_: rprev: {
      fetchCargoVendor = wrapFetchCargoVendor rprev.fetchCargoVendor;
    });
}

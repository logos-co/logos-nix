# Nim 2.2.10 for the Windows target — BUILD-side, like ./native-overlay.nix.
#
# libverifproxy (nimbus-eth1) builds with USE_SYSTEM_NIM=1, because
# nimbus-build-system otherwise clones its pinned Nim over the network and the
# sandbox forbids that. The substituted compiler must then be the 2.2.10 nimbus
# pins: on the pin's 2.2.4, beacon_chain/spec/state_transition_block.nim stops
# with "invalid type: 'typeof(SomeBeaconBlockBody)' in this context".
#
# NOT A PIN BUMP: `nixpkgs-windows` is three days short of
# NixOS/nixpkgs@81daafea8c72 ("nim: 2.2.4 -> 2.2.10"), and moving it drags the
# mingw toolchain with it. libstdc++-6.dll and friends resolve by FILENAME once
# a plugin and its dependencies share a directory, so every Windows consumer
# would have to relock in lockstep. This moves Nim and nothing else.
#
# BUILD-side because the cross set's `nim` is a wrapper carrying the mingw
# toolchain configuration (`x86_64-w64-mingw32-nim-wrapper`) around a native
# compiler, and nim-2_2/package.nix defaults that compiler to
# `buildPackages.nim-unwrapped-2_2`. `crossOverlays` never reach buildPackages.
final: prev:

let
  lib = final.lib;
  version = "2.2.10";

  # 81daafea also swapped extra-mangling-2.patch for a shorter
  # extra-mangling.patch — 2.2.10's modulepaths.nim no longer takes the hunk
  # that rot13'd mangleModuleName. It carried the other three over unchanged
  # (verified byte-identical), so those are reused in place.
  oldMangling = "extra-mangling-2.patch";
  keptPatches = builtins.filter (p: !lib.hasSuffix oldMangling (toString p))
    prev.nim-unwrapped-2_2.patches;

  # 2.2.10's excpt.nim adds a cstring to a string under -d:nativeStacktrace and
  # no longer compiles; 81daafea drops that flag and -d:useGnuReadline with it.
  # Filtered rather than respelled so --cpu/--os stay upstream's. How many go
  # is stage-dependent: -d:nativeStacktrace is Linux/Darwin-only to begin with.
  droppedKoch = [ "-d:nativeStacktrace" "-d:useGnuReadline" ];
  keptKoch = builtins.filter (a: !builtins.elem a droppedKoch)
    prev.nim-unwrapped-2_2.kochArgs;
in
{
  nim-unwrapped-2_2 =
    assert lib.assertMsg (lib.versionOlder prev.nim-unwrapped-2_2.version version)
      ("nim overlay is stale: nixpkgs-windows ships nim "
        + prev.nim-unwrapped-2_2.version
        + "; drop nix/windows/nim-overlay.nix and its patch");
    assert lib.assertMsg
      (builtins.length keptPatches == builtins.length prev.nim-unwrapped-2_2.patches - 1)
      "nim overlay drift: ${oldMangling} is not in nim-unwrapped-2_2.patches";
    assert lib.assertMsg
      (builtins.length keptKoch < builtins.length prev.nim-unwrapped-2_2.kochArgs)
      "nim overlay drift: kochArgs carries none of ${toString droppedKoch}";
    prev.nim-unwrapped-2_2.overrideAttrs (_: {
      inherit version;

      src = final.fetchurl {
        url = "https://nim-lang.org/download/nim-${version}.tar.xz";
        hash = "sha256-eVe37QBCBrzxC8xPO0dEFTh45i8kMVUqmo6dP0Do1dU=";
      };

      patches = keptPatches ++ [ ./nim-extra-mangling.patch ];
      kochArgs = keptKoch;
    });
}

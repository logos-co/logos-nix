# Point `fetchCrate` at static.crates.io on the current nixpkgs pin. Same 403 as
# the two sibling overlays, third fetcher: this one pulls a crate's own SOURCE
# tarball, not a vendored dependency. logos-co/logos-nix#9 left it alone
# believing nothing fetched through it -- untrue of a module closure, which
# reaches rav1e and cargo-c via qtdeclarative -> qtsvg -> jasper -> libheif.
#
# `registryDl` is fetchCrate's own documented argument, so a caller naming a
# registry still wins and no file is re-instantiated.
final: prev:
let
  inherit (prev) lib;

  apiPrefix = "https://crates.io/api/v1/crates";
  cdnPrefix = "https://static.crates.io/crates";

  fetchCrateFile = prev.path + "/pkgs/build-support/rust/fetchcrate.nix";
  fetchCrateSrc = builtins.readFile fetchCrateFile;

  alreadyFixed = lib.hasInfix cdnPrefix fetchCrateSrc;
in
if alreadyFixed then
  { }
else
  assert lib.assertMsg (lib.hasInfix apiPrefix fetchCrateSrc)
    "fetch-crate-static-crates-io overlay: ${toString fetchCrateFile} references neither ${apiPrefix} nor ${cdnPrefix}; the registry default moved";
  {
    fetchCrate = args: prev.fetchCrate ({ registryDl = cdnPrefix; } // args);
  }

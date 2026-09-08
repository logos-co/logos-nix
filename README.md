# logos-nix

Shared Nix infrastructure for all Logos projects. Provides a single pinned `nixpkgs` and common build dependencies so downstream repos stay in sync without depending on an actual project as their flake root.

Previously, [`logos-cpp-sdk`](https://github.com/logos-co/logos-cpp-sdk) served as the `follows` root. This caused unnecessary cache invalidation on every SDK commit and coupled infrastructure concerns to an active development project.

## What it provides

| Output | Description |
|---|---|
| `nixpkgs` input | Pinned `nixos-unstable` revision shared across all projects |
| `devShells.default` | Common dev environment: `cmake`, `ninja`, `pkg-config`, `qt6.qtbase`, `qt6.qtremoteobjects` |
| `lib.forAllSystems` | Helper to generate outputs for all supported systems |
| `lib.supportedSystems` | `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, `x86_64-linux` |
| `lib.nativeOverlays` | Every overlay that belongs on a Linux/macOS package set, in order, as a list. This is what a consumer doing its own `import nixpkgs { overlays = ...; }` should apply — naming individual `lib.overlays.*` entries means a future overlay silently does not reach it. Never includes the Windows overlays, which must not touch a native set. |
| `lib.overlays.fetchCargoVendorUserAgent` | Makes `rustPlatform.fetchCargoVendor` send a User-Agent on the current pin (crates.io 403s python-requests' default). Applied by `forAllSystems`/`forAllTargets`/`legacyPackages`; a consumer that does its own `import nixpkgs` should apply `lib.nativeOverlays` rather than naming this one. See `nix/overlays/fetch-cargo-vendor-user-agent.nix`. |
| `lib.overlays.importCargoLockStaticCratesIo` | Points `rustPlatform.importCargoLock` at `static.crates.io` on the current pin (crates.io's `/api/v1/crates` 403s the `curl/...` User-Agent `fetchurl` sends). This is the fetcher a `cargoLock` build uses; `cargoHash` builds use `fetchCargoVendor` above, so a repo that builds Rust needs whichever matches its packages, or both. Applied by `forAllSystems`/`forAllTargets`/`legacyPackages`; a consumer that does its own `import nixpkgs` should apply `lib.nativeOverlays` rather than naming this one. See `nix/overlays/import-cargo-lock-static-crates-io.nix`. |
| `lib.overlays.fetchCrateStaticCratesIo` | Points `fetchCrate` at `static.crates.io` on the current pin — the third fetcher, and the one that pulls a crate's own *source* tarball rather than a vendored dependency. Reached from a module closure via qtdeclarative → qtsvg → jasper → libheif (`rav1e`, `cargo-c`). Swaps `fetchCrate`'s own `registryDl` default, so a caller naming a registry still wins. See `nix/overlays/fetch-crate-static-crates-io.nix`. |

## Usage

### As a follows root (most projects)

```nix
{
  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };
}
```

### Using the dev shell

```nix
{
  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };

  outputs = { self, nixpkgs, logos-nix }:
    logos-nix.lib.forAllSystems ({ system, pkgs }: {
      devShells.default = pkgs.mkShell {
        inputsFrom = [ logos-nix.devShells.${system}.default ];
        # add project-specific deps here
      };
    });
}
```

## Migration from logos-cpp-sdk

```diff
 inputs = {
-  logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk";
-  nixpkgs.follows = "logos-cpp-sdk/nixpkgs";
+  logos-nix.url = "github:logos-co/logos-nix";
+  nixpkgs.follows = "logos-nix/nixpkgs";
+  logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk";  # only if you need the SDK
 };
```

Then run `nix flake update` to re-lock.


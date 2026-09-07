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
| `packages.aarch64-android.*` | Android (arm64-v8a) cross target: Qt 6.11.1, `androidPkgs`, and `mkQtAndroidApk`. See [Android target](#android-target-aarch64-android). |
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


## iOS targets (`aarch64-ios-simulator`, `aarch64-ios`)

Qt 6.11.1 built from source as static frameworks for the iOS simulator and for
iOS devices, on the same cross pin as Windows. Only aarch64-darwin with Xcode installed can build it.

```bash
nix build .#packages.aarch64-ios-simulator.qtbase        # also qtdeclarative, qtshadertools, qtsvg
nix build .#packages.aarch64-ios.qtbase                  # device (iphoneos SDK)
nix build .#legacyPackages.aarch64-darwin.pkgsIosSimulator.qt6.qtbase   # the full cross sets: pkgsIosSimulator, pkgsIos
```

The pseudo-system is opt-in: `lib.forAllMobileTargets` iterates `lib.mobileTargets`
(`aarch64-ios-simulator`, `aarch64-ios`; Android keys join the same list), while
`lib.forAllTargets` stays native + Windows. A consumer gets `pkgs.logosQtCrossCmakeFlags`
(appendable `-D` flags, `[]` natively) and `pkgs.logosQtCrossToolchainFile`
(`qt.toolchain.cmake` of the iOS qtbase, to pass as `CMAKE_TOOLCHAIN_FILE`).

An app's own static-archive stage is `pkgs.mkIosCmakeStage { pname; version; src;
sourceDir ? "."; cmakeFlags ? []; buildInputs ? []; }`: the same Xcode-clang setup
the Qt modules use (`nix/ios/xcode-clang.nix`), the toolchain file and cross flags
applied, Qt on the path, and a post-install gate that fails on any dynamic image.

**Purity boundary.** Everything iOS compiles with Xcode's clang and the
iPhoneSimulator or iPhoneOS SDK from `/Applications/Xcode.app`, which cannot live in the
store, so those derivations are `__noChroot`. They still produce
ordinary cacheable store paths, but nothing iOS is bit-for-bit reproducible.
The default macOS `sandbox = false` needs nothing; a machine with a strict
sandbox must set `sandbox = relaxed`. An app's own Xcode-generator configure,
`xcodebuild` and `xcrun simctl` steps against the store Qt stay outside nix.

**Xcode gate.** `nix/ios/xcode-wrapper.nix` is named after the declared Xcode
version and build (`iosXcodeVersion`/`iosXcodeBuild` in `flake.nix`), so they
are in every dependent hash, and its setup hook fails any build early when the
installed Xcode differs, naming both. Bumping Xcode means bumping those two
strings and rebuilding Qt.

**Prebuilt fallback.** If from-source ever breaks on a new Qt or Xcode, the
documented fallback is Qt's official iOS archives as fixed-output fetches behind
the same `packages.aarch64-ios*.*` names, moving all Xcode
impurity into the app's link step. Not implemented: from-source works.

## Android target (`aarch64-android`)

Qt 6.11.1 cross-built from nixpkgs' `qt6` recipe for `arm64-v8a`, on the same
cross pin as Windows, plus a composed `androidenv` SDK/NDK and
`mkQtAndroidApk`, which packages a Qt CMake project as a debug-signed APK
entirely inside a derivation. Builds from x86_64-linux under a strict sandbox
and from aarch64-darwin.

```bash
nix build .#packages.aarch64-android.qtbase          # also qtdeclarative, qtshadertools, qtsvg
nix build .#legacyPackages.x86_64-linux.pkgsAndroid.qt6.qtbase   # the full cross set
nix build .#checks.x86_64-linux.android-apk          # smallest mkQtAndroidApk consumer
```

`packages.aarch64-android.*` is pinned to the x86_64-linux build platform: a
flake output path cannot depend on the machine evaluating it under pure eval.
From aarch64-darwin use `legacyPackages.aarch64-darwin.pkgsAndroid.*`, the
same expression with `localSystem` swapped; the APK check is x86_64-linux only,
and its consumer builds from a Mac with:

```bash
nix build --impure --expr \
  '(builtins.getFlake (toString ./.)).legacyPackages.aarch64-darwin.pkgsAndroid.callPackage ./nix/android/check-apk {}'
```

The pseudo-system is opt-in: `lib.forAllMobileTargets` iterates `lib.mobileTargets`
(`aarch64-android`; iOS keys join the same list), while `lib.forAllTargets` stays
native + Windows. A consumer gets `pkgs.logosQtCrossCmakeFlags`
(appendable `-D` flags, `[]` natively) and `pkgs.logosQtCrossToolchainFile` (the
NDK's `android.toolchain.cmake`, to pass as `CMAKE_TOOLCHAIN_FILE`), plus
`pkgs.androidPkgs` (the composed SDK/NDK), `pkgs.logosQtHost` (the
build-platform Qt at the same version, for `androiddeployqt`) and
`pkgs.mkQtAndroidApk`.

### Packaging an APK

```nix
pkgs.mkQtAndroidApk {
  pname = "my-app";
  version = "1.0";
  src = ./.;                       # a CMake project using qt_add_executable
  target = "my_app";               # the qt_add_executable target
  packageName = "io.logos.myapp";  # equals the target's QT_ANDROID_PACKAGE_NAME
  # abi ? androidPkgs.abi; qtModules ? [ qtbase qtdeclarative qtsvg ]
}
```

`$out/<pname>-<version>.apk` is signed with the committed debug key
(`nix/android/debug.keystore`) and installs with `adb install -r -g`. Every
shipped `.so` is read with `llvm-readelf` and the build fails if any `DT_NEEDED`
is neither packaged nor in the NDK's stub libraries for the target API level.
That gate sees link-time `DT_NEEDED` only, never a `dlopen`, which is exactly
where the OpenSSL gap below lives. See `nix/android/check-apk/` for the
smallest complete consumer.

### Adding an ABI

One ABI is one pseudo-system: the NDK triple, the nixpkgs `crossSystem` and
every Qt library are per-ABI. To add `armeabi-v7a`, add an `armv7a-android` key
to `lib.mobileTargets` with `config = "armv7a-unknown-linux-androideabi"` and
`abi = "armeabi-v7a"`; `ndkTriple` in the overlay already maps the four ABIs. A
multi-ABI APK then merges the per-ABI `libs/` trees before gradle runs — slice
09, not this one.

### Gotchas

Qt refuses to configure for Android without the NDK's own
`android.toolchain.cmake`, which `set()`s `CMAKE_C_COMPILER` to the NDK clang and
so bypasses the nixpkgs cc-wrapper for qtbase itself. Target *dependencies* still
go through the wrapper; both resolve to the same NDK clang, so the ABI matches.

Building *from* aarch64-darwin needs `xcbuild` in `nativeBuildInputs`, even
though nothing Apple is targeted: Qt's `qt_auto_detect_apple()` guards only on
CMake's host-derived `APPLE` and calls `xcrun` before the Android toolchain file
is read. Expect `patchelf: command not found` warnings from nixpkgs' NDK
toolchain derivation on that platform — nixpkgs runs the ELF fixup for the
Android host without putting patchelf on a darwin build platform's PATH. It is
noise; fixing it would change the toolchain hash and rebuild all of Qt.

Qt is built against its own `src/3rdparty` copies of zlib, PCRE2, libb2,
double-conversion, libpng, libjpeg, md4c, FreeType, HarfBuzz and SQLite, not
nixpkgs'. This is not a preference: a nixpkgs system library becomes a
`DT_NEEDED` soname that `androiddeployqt` does not bundle and Android does not
provide, and the app dies at its first `dlopen` with `UnsatisfiedLinkError`
(measured on a physical arm64 device). `mkQtAndroidApk`'s `DT_NEEDED` gate is
what turns that into a build failure.

**Known limitation.** Qt is configured with `openssl_runtime`, not
`openssl_linked`, which is how Qt's own Android builds ship: `libQt6Network`
`dlopen`s libssl at run time. Nothing bundles it yet, so an app that needs TLS
must add a per-ABI `libssl`/`libcrypto` via `QT_ANDROID_EXTRA_LIBS`.

### Regenerating the gradle lock

`nix/android/deps.json` is the `gradle.fetchDeps` lockfile, and the only part
of an APK build that ever touches the network. It locks Qt's gradle template,
not any app, so one file serves every `mkQtAndroidApk` consumer. The build
itself runs in the ordinary sandbox with no network at all: nixpkgs' `mitmCache`
hook starts a local `mitm-cache` proxy that replays this file, and gradle is
pointed at it. Regenerate (never hand-edit) from the repo root with:

```
$(nix build --no-link --print-out-paths \
    .#checks.x86_64-linux.android-apk.mitmCache.updateScript)
```

The update task is `assembleDebug`, not nixpkgs' default `nixDownloadDeps`, so
the lock holds exactly what a real build resolves. aapt2 is pinned to the SDK's
own binary rather than Maven's, which keeps per-build-platform artifacts out of
the lock — the same `deps.json` works from x86_64-linux and aarch64-darwin.

Measured on x86_64-linux (WSL, 32 cores, `--cores 16 --max-jobs 2`, target
dependencies and the SDK already in the store): the four Qt modules build in
**5m28s**; their combined closure is **4.6 GiB**, of which **4.2 GiB** is the
androidenv SDK + NDK. An APK derivation takes about a minute on top; a
one-window app is 19 MiB.

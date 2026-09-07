{
  description = "Logos Nix — shared Nix infrastructure for all Logos projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # WINDOWS TARGET ONLY. Deliberately a second, newer nixpkgs — the one
    # exception to this repo's "never add a separate nixpkgs pin" rule, scoped
    # so it can never reach a Linux or macOS build.
    #
    # Why: this pin exists for upstream's mingw cross fixes, which our native
    # pin predates — notably the libjpeg-turbo mingw-boolean.patch repair that
    # landed 2026-01-09. Without it the overlay has to carry that patch itself.
    #
    # IT IS *NOT* HERE TO FIX W1 (plugin DLL search), whatever an earlier
    # revision of this comment claimed. Qt loads plugins with a bare
    # LoadLibrary, so a module in its own directory cannot resolve a vendored
    # DLL sitting beside it. That was measured on real Windows against Nix-built
    # 6.9.2, and the belief that 6.11.1 fixed it came from an MSYS2 build — the
    # exact proxy this repo's own Stage 0b lesson says never to trust for
    # Qt-internals questions. Re-measured 2026-08-06 on real Windows against
    # THIS pin's Nix-built Qt 6.11.1 (QT_RUNTIME=6.11.1, verified off
    # Qt6Core.dll's version resource), module dir isolated:
    #     plain                          -> LOAD=FAILURE "The specified module
    #                                       could not be found."
    #     LOAD_WITH_ALTERED_SEARCH_PATH  -> LOAD=SUCCESS, vendored DLL resolved
    #                                       from the module's own directory
    #     vendored DLL moved next to exe -> LOAD=SUCCESS  (control)
    # So W1 is real at 6.11.1 and is fixed in code, in logos-module's
    # LogosModule::loadFromPath (see src/win_dll_search.cpp), not by this pin.
    #
    # Cost: Windows ships Qt 6.11.1 while Linux/macOS stay on 6.9.2, and
    # logos-cpp-sdk notes "the QRO wire is Qt-version-sensitive". Every process
    # in a Logos node talks over same-machine local sockets / named pipes, so a
    # Windows install is internally consistent; there is no cross-platform QtRO
    # link today. Revisit if one is ever introduced.
    #
    # Pinned to the exact base that logos-co/nixpkgs@mingw-integration was
    # rebased onto, so that branch stays a byte-for-byte reference.
    nixpkgs-windows.url = "github:NixOS/nixpkgs/b5aa0fbd538984f6e3d201be0005b4463d8b09f8";
  };

  outputs = { self, nixpkgs, nixpkgs-windows }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      # Build platforms from which the Windows target may be produced.
      #
      # The overlay evaluates from Darwin too, but builds belong on Linux:
      # wine (for smoke tests) does not exist for aarch64-darwin at all, and
      # upstream nixpkgs only exercises mingw cross from x86_64-linux via
      # release-cross.nix.
      windowsBuildSystems = [ "x86_64-linux" ];

      # x86_64-w64-mingw32 with UCRT rather than the legacy MSVCRT. UCRT is
      # MSYS2's default, has correct C99 printf and UTF-8 locale behaviour, and
      # is what Microsoft ships on Windows 10+. (`mingwW64` in
      # lib/systems/examples.nix is the MSVCRT spelling, and upstream carries a
      # removal TODO above it.)
      windowsCrossSystem = {
        config = "x86_64-w64-mingw32";
        libc = "ucrt";
      };

      windowsCrossOverlay = import ./nix/windows/cross-overlay.nix;
      windowsNativeOverlay = import ./nix/windows/native-overlay.nix;

      # iOS targets. Same cross pin as Windows (Qt 6.11.1); the Xcode version
      # and build are part of every iOS derivation's hash via
      # nix/ios/xcode-wrapper.nix. Only aarch64-darwin can build these.
      # See nix/ios/cross-overlay.nix.
      iosXcodeVersion = "26.6";
      iosXcodeBuild = "17F113";
      iosBuildSystems = [ "aarch64-darwin" ];
      iosCrossSystems = {
        aarch64-ios-simulator = {
          config = "arm64-apple-ios";
          darwinPlatform = "ios-simulator";
        };
        aarch64-ios = {
          config = "arm64-apple-ios";
          darwinPlatform = "ios";
        };
      };
      iosCrossOverlay = import ./nix/ios/cross-overlay.nix;

      mkIosPkgs =
        { target ? "aarch64-ios-simulator"
        , buildSystem ? "aarch64-darwin"
        , xcodeVersion ? iosXcodeVersion
        , xcodeBuild ? iosXcodeBuild
        }: import nixpkgs-windows {
          localSystem = buildSystem;
          crossSystem = iosCrossSystems.${target} // { xcodeVer = xcodeVersion; inherit xcodeBuild; };
          crossOverlays = [ iosCrossOverlay ];
        };

      # Android target. Same cross pin as Windows (Qt 6.11.1); see
      # nix/android/cross-overlay.nix. arm64-v8a only in this slice -- one ABI is
      # one pseudo-system, because the NDK triple, the nixpkgs crossSystem and
      # every Qt library are per-ABI.
      androidAbi = "arm64-v8a";

      # Qt 6.11 defaults to and requires API 28 (QtAutoDetectHelpers.cmake picks
      # android-28 when nothing else asks). The same number is `androidSdkVersion`
      # on the cross system, which nixpkgs bakes into
      # `--target=aarch64-linux-android<N>` for every target dependency -- Qt and
      # its deps have to agree on it or the app links against symbols its own
      # minSdk does not promise.
      androidApiLevel = "28";

      # Compile-time SDK: the android.jar the Java side and androiddeployqt use.
      # Independent of androidApiLevel, which is the runtime floor. 36 / 36.0.0
      # are floors, not preferences: the Android Gradle Plugin that Qt 6.11's
      # build.gradle template pins (9.0.0) refuses build-tools below 36.0.0 and
      # then tries to install them into the read-only store.
      androidCompileSdkVersion = "36";
      androidBuildToolsVersion = "36.0.0";

      # The version `lib.systems.examples.aarch64-android-prebuilt` pins, so
      # `androidndkPkgs_27` and our own composition resolve the same tarball.
      androidNdkVersion = "27.0.12077973";

      androidBuildSystems = [ "x86_64-linux" "aarch64-darwin" ];

      androidCrossSystem = {
        config = "aarch64-unknown-linux-android";
        rust.rustcTarget = "aarch64-linux-android";
        androidSdkVersion = androidApiLevel;
        androidNdkVersion = "27";
        useAndroidPrebuilt = true;
      };

      # The SDK and NDK are redistributable-but-unfree Google binaries behind a
      # click-through licence. Scoped to the Android package set only.
      androidConfig = {
        allowUnfree = true;
        android_sdk.accept_license = true;
      };

      # One overlay per build platform, because it closes over the build-platform
      # package set (host Qt, SDK, NDK).
      mkAndroidCrossOverlay = buildSystem: import ./nix/android/cross-overlay.nix {
        # NOT `final.pkgsBuildBuild`: under a cross set that attribute's
        # `pkgsi686Linux` comes out with hostPlatform=aarch64-unknown-linux-android
        # and buildPlatform=i686-linux, and androidenv's tools.nix reaches into it
        # for the 32-bit runtime libraries the legacy SDK tools need. The result
        # is an eval failure ("unsupported CPU i686", from openjdk) with nothing
        # in the trace pointing at the real cause.
        buildPkgs = import nixpkgs-windows {
          system = buildSystem;
          config = androidConfig;
        };
        abi = androidAbi;
        apiLevel = androidApiLevel;
        compileSdkVersion = androidCompileSdkVersion;
        buildToolsVersion = androidBuildToolsVersion;
        ndkVersion = androidNdkVersion;
      };

      mkAndroidPkgs =
        { buildSystem ? "x86_64-linux" }: import nixpkgs-windows {
          localSystem = buildSystem;
          crossSystem = androidCrossSystem;
          config = androidConfig;
          crossOverlays = [ (mkAndroidCrossOverlay buildSystem) ];
        };

      # Mobile pseudo-systems are OPT-IN, unlike x86_64-windows: consumers
      # that wrap forAllTargets map build systems for Windows only, and
      # `stdenv.isDarwin` is true for an iOS host, so adding these keys to
      # forAllTargets would misroute them. Android adds its keys here.
      mobileTargets = {
        aarch64-ios-simulator = {
          buildSystem = "aarch64-darwin";
          pkgs = mkIosPkgs { target = "aarch64-ios-simulator"; };
        };
        aarch64-ios = {
          buildSystem = "aarch64-darwin";
          pkgs = mkIosPkgs { target = "aarch64-ios"; };
        };
        aarch64-android = {
          buildSystem = "x86_64-linux";
          pkgs = mkAndroidPkgs { buildSystem = "x86_64-linux"; };
        };
      };
      forAllMobileTargets = f:
        nixpkgs.lib.mapAttrs (system: t: f { inherit system; inherit (t) pkgs buildSystem; }) mobileTargets;

      # Native (Linux/macOS) package set on the workspace pin. Carries the
      # crates.io 403 fixes until the pin is bumped past NixOS/nixpkgs#512735
      # and #524979; see the two overlays under nix/overlays/.
      # Not applied to the Windows set: nixpkgs-windows already contains the
      # upstream fix.
      fetchCargoVendorUserAgentOverlay = import ./nix/overlays/fetch-cargo-vendor-user-agent.nix;
      importCargoLockStaticCratesIoOverlay = import ./nix/overlays/import-cargo-lock-static-crates-io.nix;
      fetchCrateStaticCratesIoOverlay = import ./nix/overlays/fetch-crate-static-crates-io.nix;
      nativeOverlays = [
        fetchCargoVendorUserAgentOverlay
        importCargoLockStaticCratesIoOverlay
        fetchCrateStaticCratesIoOverlay
      ];
      mkNativePkgs = system: import nixpkgs { inherit system; overlays = nativeOverlays; };

      # Package set targeting Windows, built FROM `buildSystem`.
      #
      # Uses `nixpkgs-windows` (Qt 6.11.1), NOT the workspace pin — see the
      # input comment for why. Nothing else in this flake touches it, so the
      # native Linux/macOS closures are unaffected by Windows support existing.
      #
      # The BUILD-side overlay is only needed where wine is unavailable (see
      # native-overlay.nix). Applying it unconditionally would be actively
      # harmful: it changes the NATIVE glib's hash, which invalidates the
      # binary cache for everything downstream of glib on the build platform
      # -- gtk3, gdk-pixbuf, at-spi2-core, json-glib, graphviz ... -- and those
      # then rebuild from source purely to produce a Windows artifact.
      #
      # wine64.meta.platforms is [x86_64-linux x86_64-darwin], so only
      # aarch64-darwin needs it.
      needsNativeOverlay = buildSystem: buildSystem == "aarch64-darwin";

      mkWindowsPkgs =
        { buildSystem
        , libc ? windowsCrossSystem.libc
        }: import nixpkgs-windows {
          localSystem = buildSystem;
          crossSystem = windowsCrossSystem // { inherit libc; };
          overlays = nixpkgs.lib.optional (needsNativeOverlay buildSystem) windowsNativeOverlay;
          crossOverlays = [ windowsCrossOverlay ]; # HOST-side fixes
        };

      forAllSystems = f:
        nixpkgs.lib.genAttrs supportedSystems (system:
          f {
            inherit system;
            pkgs = mkNativePkgs system;
          });

      # forAllSystems, plus the Windows target keyed under the pseudo-system
      # "x86_64-windows".
      #
      # Keying it as a system rather than as a package-name suffix is
      # deliberate: consumer flakes are full of `dep.packages.${system}.foo`
      # interpolations (49 of them across logos-logoscore-cli and
      # logos-basecamp alone) and every one keeps working unchanged.
      #
      # A cross derivation's `system` attribute is its BUILD platform, so
      # `packages.x86_64-windows.*` evaluates anywhere but realises on
      # x86_64-linux.
      forAllTargets = f:
        nixpkgs.lib.genAttrs (supportedSystems ++ [ "x86_64-windows" ]) (system:
          if system == "x86_64-windows" then
            f {
              inherit system;
              pkgs = mkWindowsPkgs { buildSystem = "x86_64-linux"; };
            }
          else
            f {
              inherit system;
              pkgs = mkNativePkgs system;
            });
    in
    {
      lib = {
        inherit
          supportedSystems
          forAllSystems
          forAllTargets
          mkWindowsPkgs
          nativeOverlays
          windowsBuildSystems
          windowsCrossSystem
          mkIosPkgs
          iosBuildSystems
          iosCrossSystems
          iosXcodeVersion
          iosXcodeBuild
          mkAndroidPkgs
          # A function of the build system, not a plain overlay: it closes over
          # the build-platform SDK/NDK, so there is no one correct instance.
          mkAndroidCrossOverlay
          androidBuildSystems
          androidCrossSystem
          androidAbi
          androidApiLevel
          mobileTargets
          forAllMobileTargets
          ;

        overlays = {
          windows = windowsCrossOverlay;
          windowsNative = windowsNativeOverlay;
          ios = iosCrossOverlay;
          fetchCargoVendorUserAgent = fetchCargoVendorUserAgentOverlay;
          importCargoLockStaticCratesIo = importCargoLockStaticCratesIoOverlay;
          fetchCrateStaticCratesIo = fetchCrateStaticCratesIoOverlay;
        };
      };

      # nix build .#legacyPackages.x86_64-linux.pkgsWindows.qt6.qtbase
      legacyPackages = nixpkgs.lib.genAttrs supportedSystems (system:
        (mkNativePkgs system) // {
          pkgsWindows = mkWindowsPkgs { buildSystem = system; };
        } // nixpkgs.lib.optionalAttrs (builtins.elem system iosBuildSystems) {
          pkgsIosSimulator = mkIosPkgs { buildSystem = system; };
          pkgsIos = mkIosPkgs { buildSystem = system; target = "aarch64-ios"; };
        } // nixpkgs.lib.optionalAttrs (builtins.elem system androidBuildSystems) {
          pkgsAndroid = mkAndroidPkgs { buildSystem = system; };
        });

      # nix build .#packages.aarch64-ios-simulator.qtbase (or aarch64-ios)
      # nix build .#packages.aarch64-android.qtbase
      # Flat derivations only (flake schema); the full qt6 scope and
      # mkQtAndroidApk are under legacyPackages.<buildSystem>.pkgsIosSimulator
      # / .pkgsIos / .pkgsAndroid like pkgsWindows.
      packages = forAllMobileTargets ({ pkgs, ... }:
        { inherit (pkgs.qt6) qtbase qtdeclarative qtshadertools qtsvg; }
        // nixpkgs.lib.optionalAttrs (pkgs ? xcodeWrapper) { inherit (pkgs) xcodeWrapper; });

      # Drift guard for the Windows overlay.
      #
      # The overlay's dangerous failure mode is SILENT: an input filter that
      # matches nothing, or an `overrideAttrs` that drops `meta.platforms`,
      # leaves a package that still evaluates while no longer being fixed.
      # These assertions encode the properties the overlay exists to provide,
      # so a Qt bump that invalidates one fails here in seconds rather than
      # hours into a cross build.
      checks = forAllSystems ({ system, pkgs, ... }:
        let
          inherit (pkgs) lib;
          w = mkWindowsPkgs { buildSystem = system; };

          # The four Qt modules Logos actually consumes.
          requiredQtModules = [ "qtbase" "qtdeclarative" "qtremoteobjects" "qtsvg" ];

          hasFlagPrefix = drv: prefix:
            builtins.any (f: lib.hasPrefix prefix f) (drv.cmakeFlags or [ ]);

          qtbaseInputNames =
            map (p: p.pname or p.name or "")
              (builtins.filter lib.isDerivation
                ((w.qt6.qtbase.buildInputs or [ ])
                  ++ (w.qt6.qtbase.propagatedBuildInputs or [ ])));

          excludes = n: !(builtins.any (x: lib.hasPrefix n x) qtbaseInputNames);

          assertions = [
            # Every required module resolves for the Windows host...
            {
              name = "all four Qt modules resolve";
              ok = builtins.all (m: builtins.isString w.qt6.${m}.drvPath) requiredQtModules;
            }
            # ...and still says so in its meta. Catches the qtModule trap:
            # qtModule.nix attaches meta with `//` AFTER mkDerivation returns,
            # so a naive overrideAttrs silently drops meta.platforms.
            {
              name = "Qt modules still declare x86_64-windows";
              ok = builtins.all
                (m: builtins.elem "x86_64-windows" (w.qt6.${m}.meta.platforms or [ ]))
                requiredQtModules;
            }
            # qtbase hardcodes -DQT_FEATURE_libproxy=ON while the overlay
            # filters libproxy out of its inputs, so this override is
            # load-bearing, not cosmetic.
            {
              name = "qtbase disables libproxy";
              ok = hasFlagPrefix w.qt6.qtbase "-DQT_FEATURE_libproxy=OFF";
            }
            {
              name = "qtbase disables vulkan";
              ok = hasFlagPrefix w.qt6.qtbase "-DQT_FEATURE_vulkan=OFF";
            }
            # repc is a build-platform tool in its own store path, which
            # -DQT_HOST_PATH=<qtbase> cannot reach.
            {
              name = "qtremoteobjects points at build-platform repc";
              ok = hasFlagPrefix w.qt6.qtremoteobjects "-DQt6RemoteObjectsTools_DIR=";
            }
            # qsb is the same shape of build-platform tool, and its absence is
            # the WORST failure mode in this file: without it qtdeclarative
            # still configures, installs and satisfies every find_package --
            # it just silently ships no Qt6Quick.dll, no QtQuick qmldir and no
            # QtQuick.Controls. The whole port linked such a Qt for weeks
            # because the assertion below it ("required Qt modules resolve")
            # stayed true throughout. Note nixpkgs DOES pass a flag here, but
            # aims it at Qt6ShaderTools (the target config) rather than
            # Qt6ShaderToolsTools (the host tools), so asserting on the prefix
            # alone would pass against the broken value -- match the suffix.
            {
              name = "qtdeclarative points at build-platform qsb";
              ok = builtins.any
                (lib.hasSuffix "/lib/cmake/Qt6ShaderToolsTools")
                (w.qt6.qtdeclarative.cmakeFlags or [ ]);
            }
            # A filter that silently matches nothing is the drift mode we fear
            # most, so assert on what it must have removed.
            { name = "qtbase drops libglvnd"; ok = excludes "libglvnd"; }
            { name = "qtbase drops libproxy"; ok = excludes "libproxy"; }
            { name = "qtbase drops vulkan"; ok = excludes "vulkan"; }
            # glib's target-python redirect held, keeping the mingw CPython
            # port out of the closure entirely.
            { name = "no target python3 in qtbase closure"; ok = excludes "python3"; }
            # cli11 is a direct logosctl dependency and is platforms.unix
            # upstream.
            { name = "cli11 available for Windows"; ok = builtins.isString w.cli11.drvPath; }
          ];

          gate = lib.foldl'
            (acc: a: acc && (lib.assertMsg a.ok "windows overlay drift: ${a.name}"))
            true
            assertions;
        in
        {
          windows-overlay = assert gate;
            pkgs.runCommand "windows-overlay-eval-gate" { } "touch $out";

          # Same for fetchCrate, whose default `registryDl` the overlay swaps.
          # unpack=false so the probe is a plain fetchurl and exposes `urls`.
          fetch-crate-overlay =
            let
              probe = pkgs.fetchCrate {
                crateName = "logos-gate-probe";
                version = "0.0.0";
                unpack = false;
                sha256 = lib.fakeSha256;
              };
              urls = toString (probe.urls or probe.url);
            in
            assert lib.assertMsg (lib.hasInfix "https://static.crates.io/crates" urls)
              "fetch-crate overlay drift: crate source not on the CDN (${urls})";
            assert lib.assertMsg (!lib.hasInfix "https://crates.io/api/v1/crates" urls)
              "fetch-crate overlay drift: API URL survives (${urls})";
            pkgs.runCommand "fetch-crate-overlay-eval-gate" { } "touch $out";

          # Drift guard for the importCargoLock rewrite (the UA overlay asserts
          # on its own hunks). Both failure modes here are silent: a rewrite
          # that stops matching still evaluates, and so does an importCargoLock
          # instantiated on the host platform, whose git-crate script then runs
          # target cargo/jq on the builder.
          # `lib.overlays` is the menu, `lib.nativeOverlays` the list consumers
          # apply wholesale. An overlay added to one and not the other ships
          # unwired -- which is exactly how the importCargoLock fix reached
          # master applying to nothing.
          overlay-exports =
            let
              crossNames = [ "windows" "windowsNative" "ios" ];
              nativeNames = builtins.attrNames (removeAttrs self.lib.overlays crossNames);
            in
            assert lib.assertMsg
              (builtins.length self.lib.nativeOverlays == builtins.length nativeNames)
              ("overlay export drift: lib.nativeOverlays has "
                + toString (builtins.length self.lib.nativeOverlays)
                + " entries but lib.overlays lists " + toString (builtins.length nativeNames)
                + " non-cross overlays (" + toString nativeNames + ")");
            pkgs.runCommand "overlay-exports-eval-gate" { } "touch $out";

          import-cargo-lock-overlay =
            let
              apiPrefix = "https://crates.io/api/v1/crates";
              cdnPrefix = "https://static.crates.io/crates";
              importCargoLockFile = pkgs.path + "/pkgs/build-support/rust/import-cargo-lock.nix";

              # Only the git branch uses `cargo`; only the registry branch, `fetchurl`.
              lockArgs = {
                lockFileContents = ''
                  version = 3

                  [[package]]
                  name = "logos-gate-registry-probe"
                  version = "0.0.0"
                  source = "registry+https://github.com/rust-lang/crates.io-index"
                  checksum = "0000000000000000000000000000000000000000000000000000000000000000"

                  [[package]]
                  name = "logos-gate-git-probe"
                  version = "0.0.0"
                  source = "git+https://logos.invalid/probe#0000000000000000000000000000000000000000"
                '';
                outputHashes."logos-gate-git-probe-0.0.0" = lib.fakeSha256;
              };

              cargoProbe = pkgs.emptyDirectory;
              overlaid = p: (p.makeRustPlatform { cargo = cargoProbe; rustc = cargoProbe; }).importCargoLock;
              # Must land on the same store path as `overlaid`: fetchurl is
              # fixed-output, so rewriting its URL cannot move the vendor dir.
              reference = p: p.buildPackages.callPackage importCargoLockFile { cargo = cargoProbe; } lockArgs;

              probe = (overlaid pkgs).override (orig:
                assert lib.assertMsg (orig.cargo.outPath == cargoProbe.outPath)
                  "import-cargo-lock overlay drift: cargo never reaches importCargoLock";
                {
                  fetchurl = fetchurlArgs:
                    let drv = orig.fetchurl fetchurlArgs; urls = toString drv.urls;
                    in
                    assert lib.assertMsg (lib.hasInfix cdnPrefix urls)
                      "import-cargo-lock overlay drift: crate not on the CDN (${urls})";
                    assert lib.assertMsg (!lib.hasInfix apiPrefix urls)
                      "import-cargo-lock overlay drift: API URL survives (${urls})";
                    drv;
                });

              # Never a supported system, so buildPackages cannot collapse into
              # the package set and leave the placement check vacuous.
              cross = pkgs.pkgsCross.riscv64;
            in
            assert lib.assertMsg ((probe lockArgs).outPath == (reference pkgs).outPath)
              "import-cargo-lock overlay drift: the rewrite moves the vendor dir, not just the URL";
            assert lib.assertMsg (((overlaid cross) lockArgs).outPath == (reference cross).outPath)
              "import-cargo-lock overlay drift: importCargoLock is not instantiated on the build platform";
            pkgs.runCommand "import-cargo-lock-overlay-eval-gate" { } "touch $out";
        }
        // lib.optionalAttrs (builtins.elem system iosBuildSystems) (
          let
            i = mkIosPkgs { buildSystem = system; };
            d = mkIosPkgs { buildSystem = system; target = "aarch64-ios"; };
            iosQtModules = [ "qtbase" "qtdeclarative" "qtshadertools" "qtsvg" ];
            iosAssertions = [
              {
                name = "device set targets the iphoneos SDK and differs from the simulator";
                ok = builtins.elem "-DCMAKE_OSX_SYSROOT=iphoneos" d.logosQtCrossCmakeFlags
                  && d.qt6.qtbase.drvPath != i.qt6.qtbase.drvPath;
              }
              {
                name = "all four Qt modules resolve";
                ok = builtins.all (m: builtins.isString i.qt6.${m}.drvPath) iosQtModules;
              }
              # The version is the gate: a different declared Xcode must be a
              # different derivation, or a cache hit from the wrong Xcode
              # would be served as "the" Qt.
              {
                name = "xcode wrapper is named after the Xcode version and build";
                ok = i.xcodeWrapper.name == "xcode-wrapper-${iosXcodeVersion}-${iosXcodeBuild}";
              }
              {
                name = "declared Xcode version or build changes the Qt hash";
                ok = (mkIosPkgs { buildSystem = system; xcodeVersion = "0.0"; }).qt6.qtbase.drvPath
                  != i.qt6.qtbase.drvPath
                  && (mkIosPkgs { buildSystem = system; xcodeBuild = "0A0"; }).qt6.qtbase.drvPath
                  != i.qt6.qtbase.drvPath;
              }
              {
                name = "cross flags carry host Qt and the simulator SDK";
                ok = hasFlagPrefix { cmakeFlags = i.logosQtCrossCmakeFlags; } "-DQT_HOST_PATH="
                  && builtins.elem "-DCMAKE_OSX_SYSROOT=iphonesimulator" i.logosQtCrossCmakeFlags;
              }
              {
                name = "toolchain file lives in the iOS qtbase";
                ok = lib.hasPrefix "${i.qt6.qtbase}" i.logosQtCrossToolchainFile;
              }
              # The overlay applied to a NATIVE set must degrade to nothing.
              {
                name = "cross flags are empty natively";
                ok = (import nixpkgs-windows { inherit system; overlays = [ iosCrossOverlay ]; })
                  .logosQtCrossCmakeFlags == [ ];
              }
              # Same silent failure as on Windows: aim at Qt6ShaderToolsTools
              # (host qsb) or Qt Quick is quietly not built.
              {
                name = "qtdeclarative points at build-platform qsb";
                ok = builtins.any (lib.hasSuffix "/lib/cmake/Qt6ShaderToolsTools") i.qt6.qtdeclarative.cmakeFlags;
              }
            ];
            iosGate = lib.foldl'
              (acc: a: acc && (lib.assertMsg a.ok "ios overlay drift: ${a.name}"))
              true
              iosAssertions;
          in
          {
            ios-overlay = assert iosGate;
              pkgs.runCommand "ios-overlay-eval-gate" { } "touch $out";
          }
        )
        // lib.optionalAttrs (builtins.elem system androidBuildSystems) (
          let
            a = mkAndroidPkgs { buildSystem = system; };
            androidQtModules = [ "qtbase" "qtdeclarative" "qtshadertools" "qtsvg" ];

            androidInputNames =
              map (p: p.pname or p.name or "")
                (builtins.filter lib.isDerivation
                  ((a.qt6.qtbase.buildInputs or [ ])
                    ++ (a.qt6.qtbase.propagatedBuildInputs or [ ])));

            androidAssertions = [
              {
                name = "all four Qt modules resolve";
                ok = builtins.all (m: builtins.isString a.qt6.${m}.drvPath) androidQtModules;
              }
              # Qt aborts configure without the NDK's own toolchain file, and it
              # is the one CMake variable a consumer cannot just append.
              {
                name = "toolchain file lives in the NDK";
                ok = lib.hasSuffix "/build/cmake/android.toolchain.cmake" a.logosQtCrossToolchainFile;
              }
              {
                name = "cross flags are appendable -D flags only";
                ok = builtins.all (lib.hasPrefix "-D") a.logosQtCrossCmakeFlags;
              }
              {
                name = "cross flags carry host Qt and the ABI";
                ok = builtins.any (lib.hasPrefix "-DQT_HOST_PATH=") a.logosQtCrossCmakeFlags
                  && builtins.elem "-DQT_ANDROID_ABIS=${androidAbi}" a.logosQtCrossCmakeFlags;
              }
              {
                name = "qtbase targets ${androidAbi}";
                ok = hasFlagPrefix a.qt6.qtbase "-DANDROID_ABI=${androidAbi}";
              }
              # Same silent failure as on Windows: aim at
              # Qt6ShaderToolsTools (host qsb) or Qt Quick is quietly not built.
              {
                name = "qtdeclarative points at build-platform qsb";
                ok = builtins.any
                  (lib.hasSuffix "/lib/cmake/Qt6ShaderToolsTools")
                  (a.qt6.qtdeclarative.cmakeFlags or [ ]);
              }
              # Every nixpkgs system library Qt links becomes a DT_NEEDED soname
              # that androiddeployqt does not bundle and Android does not
              # provide, so the app dies at dlopen. openssl is the exception:
              # openssl_linked=OFF means it is dlopened, never NEEDED.
              {
                name = "qtbase links no system third-party libraries";
                ok = androidInputNames == [ "openssl" ];
              }
              {
                name = "qtbase uses Qt's bundled PCRE2";
                ok = hasFlagPrefix a.qt6.qtbase "-DQT_FEATURE_system_pcre2=OFF";
              }
              # Qt's apple autodetect runs on any Mac host, whatever the target,
              # and needs xcrun; without it qtbase cannot configure from darwin.
              {
                name = "a darwin build platform gets xcrun";
                ok =
                  let
                    d = (mkAndroidPkgs { buildSystem = "aarch64-darwin"; }).qt6.qtbase;
                  in
                  builtins.any (p: (p.pname or "") == "xcbuild") d.nativeBuildInputs;
              }
              # The overlay applied to a NATIVE set must degrade to nothing --
              # including the toolchain file, which is a plain string and so
              # would happily keep pointing at an NDK that cannot build for the
              # host.
              {
                name = "cross flags and toolchain file are empty natively";
                ok =
                  let
                    n = import nixpkgs-windows {
                      inherit system;
                      config = androidConfig;
                      overlays = [ (mkAndroidCrossOverlay system) ];
                    };
                  in
                  n.logosQtCrossCmakeFlags == [ ]
                  && n.logosQtCrossToolchainFile == ""
                  && !(n ? androidPkgs)
                  && !(n ? mkQtAndroidApk);
              }
              {
                name = "mkQtAndroidApk is exposed on the cross set";
                ok = lib.isFunction a.mkQtAndroidApk;
              }
              # An empty or hand-edited lockfile still evaluates and only fails
              # deep inside gradle. Count artifacts, not repositories: a lock
              # with `{"https://...": {}}` has the right shape and no content.
              {
                name = "the APK gradle lock is populated";
                ok =
                  let
                    lock = removeAttrs (lib.importJSON ./nix/android/deps.json) [
                      "!comment"
                      "!version"
                    ];
                    repos = lib.attrValues lock;
                  in
                  repos != [ ] && builtins.all (r: builtins.isAttrs r && r != { }) repos;
              }
            ];
            androidGate = lib.foldl'
              (acc: x: acc && (lib.assertMsg x.ok "android overlay drift: ${x.name}"))
              true
              androidAssertions;
          in
          {
            android-overlay = assert androidGate;
              pkgs.runCommand "android-overlay-eval-gate" { } "touch $out";
          }
          # A real APK is the only proof that androiddeployqt, gradle and the
          # lock still agree, but it builds Qt for Android from source, so a
          # plain `nix flake check` on a Mac must not pick it up.
          // lib.optionalAttrs (system == "x86_64-linux") {
            android-apk = a.callPackage ./nix/android/check-apk { };
          }
        ));

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            pkg-config
            qt6.wrapQtAppsNoGuiHook
          ];

          buildInputs = with pkgs; [
            qt6.qtbase
            qt6.qtremoteobjects
          ];
        };
      });
    };
}

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

      # Native (Linux/macOS) package set on the workspace pin. Carries the
      # crates.io 403 fixes until the pin is bumped past NixOS/nixpkgs#512735
      # and #524979; see the two overlays under nix/overlays/.
      # Not applied to the Windows set: nixpkgs-windows already contains the
      # upstream fix.
      fetchCargoVendorUserAgentOverlay = import ./nix/overlays/fetch-cargo-vendor-user-agent.nix;
      importCargoLockStaticCratesIoOverlay = import ./nix/overlays/import-cargo-lock-static-crates-io.nix;
      nativeOverlays = [
        fetchCargoVendorUserAgentOverlay
        importCargoLockStaticCratesIoOverlay
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
          ;

        overlays = {
          windows = windowsCrossOverlay;
          windowsNative = windowsNativeOverlay;
          fetchCargoVendorUserAgent = fetchCargoVendorUserAgentOverlay;
          importCargoLockStaticCratesIo = importCargoLockStaticCratesIoOverlay;
        };
      };

      # nix build .#legacyPackages.x86_64-linux.pkgsWindows.qt6.qtbase
      legacyPackages = nixpkgs.lib.genAttrs supportedSystems (system:
        (mkNativePkgs system) // {
          pkgsWindows = mkWindowsPkgs { buildSystem = system; };
        });

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
              windowsNames = [ "windows" "windowsNative" ];
              nativeNames = builtins.attrNames (removeAttrs self.lib.overlays windowsNames);
            in
            assert lib.assertMsg
              (builtins.length self.lib.nativeOverlays == builtins.length nativeNames)
              ("overlay export drift: lib.nativeOverlays has "
                + toString (builtins.length self.lib.nativeOverlays)
                + " entries but lib.overlays lists " + toString (builtins.length nativeNames)
                + " non-Windows overlays (" + toString nativeNames + ")");
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
        });

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

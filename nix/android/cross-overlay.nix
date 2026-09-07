# Android (aarch64-unknown-linux-android) cross overlay — HOST-side fixes.
#
# Applied via `crossOverlays`, so it only ever touches the Android target
# package set.  Native Linux/macOS closures are untouched.
#
# The shape mirrors ./../windows/cross-overlay.nix; the substance does not.
# Windows needed a handful of packages taught about mingw. Android needs qtbase
# taught that `hostPlatform.isLinux` being true does not mean desktop Linux.
{
  # A clean package set for the build platform. NOT `final.pkgsBuildBuild`:
  # under a cross set that attribute's `pkgsi686Linux` comes out with
  # hostPlatform=aarch64-unknown-linux-android and buildPlatform=i686-linux, and
  # androidenv's `tools.nix` reaches into it for the 32-bit runtime libraries the
  # legacy SDK tools need. The result is an eval failure ("unsupported CPU i686",
  # from openjdk) with nothing in the trace pointing at the real cause.
  buildPkgs,
  abi,
  apiLevel,
  compileSdkVersion,
  buildToolsVersion,
  ndkVersion,
}:
final: prev:

let
  # Both read from `prev`, not `final`: the guard below decides which attribute
  # NAMES this overlay contributes, and in a nixpkgs overlay the set of names
  # may not depend on `final` -- the fixpoint cannot be constructed at all.
  # Neither lib nor stdenv is overridden here, so the two agree.
  lib = prev.lib;
  isCross = !prev.stdenv.buildPlatform.canExecute prev.stdenv.hostPlatform;

  buildQt = buildPkgs.qt6;

  androidComposition = buildPkgs.androidenv.composeAndroidPackages {
    buildToolsVersions = [ buildToolsVersion ];
    platformVersions = [ compileSdkVersion ];
    abiVersions = [ abi ];
    includeNDK = true;
    inherit ndkVersion;
    includeEmulator = false;
    includeSystemImages = false;
    # androidenv's cmake is a second, unwrapped CMake that would shadow the one
    # nixpkgs already puts on PATH.
    includeCmake = false;
  };

  sdkRoot = "${androidComposition.androidsdk}/libexec/android-sdk";
  # `ndk-bundle` is androidenv's legacy alias for the same directory. The
  # versioned path is what the Gradle SDK scanner expects; via ndk-bundle it
  # warns "Observed package id ... in inconsistent location" on every task.
  ndkRoot = "${sdkRoot}/ndk/${ndkVersion}";

  # Google's tag, not nixpkgs': Apple Silicon uses the darwin-x86_64 directory,
  # whose binaries are universal.
  ndkHostTag =
    {
      x86_64-linux = "linux-x86_64";
      aarch64-linux = "linux-x86_64";
      x86_64-darwin = "darwin-x86_64";
      aarch64-darwin = "darwin-x86_64";
    }
    .${buildPkgs.stdenv.hostPlatform.system};

  ndkSysroot = "${ndkRoot}/toolchains/llvm/prebuilt/${ndkHostTag}/sysroot";

  # qt_auto_detect_apple() runs before qt_auto_detect_android() and its only
  # early-out is `if(NOT APPLE)`, which CMake answers from the HOST before
  # project() has looked at CMAKE_SYSTEM_NAME. So on a Mac it always runs, and
  # dies on `find_program(QT_XCRUN xcrun)` -- "Can't find xcrun in PATH". It
  # cannot be skipped, only satisfied: xcbuild supplies xcrun, and the macOS SDK
  # path it caches is never read by an Android target.
  appleAutodetectTools =
    lib.optional buildPkgs.stdenv.hostPlatform.isDarwin buildPkgs.xcbuild;

  # Google's triple for the ABI, which is NOT nixpkgs' `hostPlatform.config`
  # (aarch64-unknown-linux-android): the NDK sysroot spells it with three parts.
  ndkTriple =
    {
      arm64-v8a = "aarch64-linux-android";
      armeabi-v7a = "arm-linux-androideabi";
      x86_64 = "x86_64-linux-android";
      x86 = "i686-linux-android";
    }
    .${abi};

  # find_library() resolves inside the NDK sysroot but find_path() does not, so
  # Qt fails configure on "The OpenGL functionality tests failed" even though its
  # own HAVE_EGL/HAVE_GLESv2 compile tests pass. Answer the cache vars directly.
  androidGlFlags = [
    "-DEGL_INCLUDE_DIR=${ndkSysroot}/usr/include"
    "-DGLESv2_INCLUDE_DIR=${ndkSysroot}/usr/include"
  ];

  androidToolchainFile = "${ndkRoot}/build/cmake/android.toolchain.cmake";

  # -D flags only; CMAKE_TOOLCHAIN_FILE must be present in a build tree's first
  # configure, so it is separate (see logosQtCrossToolchainFile).
  androidToolchainFlags = [
    "-DANDROID_SDK_ROOT=${sdkRoot}"
    "-DANDROID_NDK_ROOT=${ndkRoot}"
    "-DANDROID_ABI=${abi}"
    "-DANDROID_PLATFORM=android-${apiLevel}"
    # QtPlatformAndroid.cmake refuses anything else.
    "-DANDROID_STL=c++_shared"
    "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH"
    "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH"
    "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH"
  ]
  ++ androidGlFlags;

  # What Qt's own build needs on top of the consumer flags.
  androidQtBuildFlags = [ "-DCMAKE_TOOLCHAIN_FILE=${androidToolchainFile}" ] ++ androidToolchainFlags;


  # qtbase's inputs are computed from `hostPlatform.isLinux`, which is TRUE for
  # Android, so the whole desktop-Linux block (X11, xcb, wayland, fontconfig,
  # systemd, dbus, glib, cups, ODBC, vulkan, libGL, icu, ...) arrives on the
  # target and has to go.
  #
  # The third-party libraries Qt CAN use go too, and that part is measured, not
  # taste: each one Qt links from nixpkgs becomes a DT_NEEDED soname
  # (libb2.so, libdouble-conversion.so.3, libjpeg.so.62, libmd4c.so.0,
  # libpcre2-16.so, libpng16.so, libzstd.so.1) that androiddeployqt does not
  # bundle and Android does not provide, and the app dies on a physical device
  # with `UnsatisfiedLinkError: dlopen failed: library "libb2.so" not found`.
  # Qt's src/3rdparty copies are what Qt's own Android binaries ship. Paired
  # with the QT_FEATURE_system_* flags below -- flip them together, never one
  # alone.
  #
  # openssl survives only because openssl_linked=OFF makes Qt dlopen it.
  keepForAndroid = [ "openssl" ];

  # Qt modules depend on each other; the filter must not cut those.
  keepInput =
    p:
    !(lib.isDerivation p)
    || (
      let n = p.pname or p.name or ""; in
      builtins.elem n keepForAndroid || lib.hasPrefix "qt" n
    );

  # Fails loudly if the patch it is asked to drop is no longer there, which is
  # the only way to notice that a Qt bump renamed or removed it.
  dropPatch =
    name: patches:
    let
      kept = builtins.filter (x: !(lib.hasInfix name (toString x))) patches;
    in
    assert lib.assertMsg (builtins.length kept < builtins.length patches)
      "logos-nix android overlay: no qtbase patch matches ${name}";
    kept;

  # TRAP (same one as the Windows overlay): qtModule.nix attaches its meta with
  # `//` AFTER mkDerivation returns, so a plain overrideAttrs drops it.
  addCmakeFlags =
    extra: drv:
    (drv.overrideAttrs (old: { cmakeFlags = (old.cmakeFlags or [ ]) ++ extra; }))
    // {
      inherit (drv) meta;
    };
in
# Everything except the two cross-flag attributes is guarded on `isCross`: this
# is a crossOverlay, and applied to a native set the qt6 scope below recurses
# forever while the SDK, NDK and toolchain file would be plain lies. Same
# contract as nix/windows/cross-overlay.nix.
lib.optionalAttrs isCross {
  # The composed SDK/NDK, exposed so mkQtAndroidApk and any consumer reach
  # exactly the SDK Qt was configured against instead of composing a second one.
  androidPkgs = androidComposition // {
    inherit
      sdkRoot
      ndkRoot
      ndkSysroot
      ndkHostTag
      ndkTriple
      abi
      apiLevel
      compileSdkVersion
      buildToolsVersion
      ndkVersion
      ;
    # The NDK's own binutils; the APK derivation reads DT_NEEDED with it.
    ndkToolchainBin = "${ndkRoot}/toolchains/llvm/prebuilt/${ndkHostTag}/bin";
    # Exactly the shared libraries Android guarantees at this API level, which
    # is the allowlist a shipped .so may name.
    ndkStubLibDir = "${ndkSysroot}/usr/lib/${ndkTriple}/${apiLevel}";
  };

  # The build-platform Qt at the same version, for androiddeployqt and the rest
  # of the host tools. Named rather than reached through pkgsBuildBuild so a
  # consumer cannot accidentally pick up a different Qt.
  logosQtHost = buildQt;

  # Qt CMake project -> debug-signed APK for this set's ABI; see mk-apk.nix.
  mkQtAndroidApk = final.callPackage ./mk-apk.nix { };

  # `enableKTLS ? hostPlatform.isLinux` is true for Android, and bionic has none
  # of the kernel-TLS socket plumbing openssl's internal/ktls.h assumes
  # (SOL_TCP, struct msghdr, CMSG_*). Qt only needs libssl/libcrypto.
  openssl = prev.openssl.override { enableKTLS = false; };

  # `--enable-jit=auto` picks sljit's dual-mapping executable allocator on
  # anything that looks like Linux, and that allocator calls secure_getenv,
  # which bionic does not provide. Everything in the Android set that wants a
  # target pcre2 -- including gnugrep, which zstd pulls in -- fails without this.
  pcre2 = prev.pcre2.overrideAttrs (old: {
    configureFlags =
      (builtins.filter (f: !(lib.hasPrefix "--enable-jit=" f)) (old.configureFlags or [ ]))
      ++ [ "--enable-jit=no" ];
  });

  # Identical to the Windows overlay's fix and for the same reason: sqlite uses
  # `hostPlatform.isStatic` as a proxy for "tcl is unavailable", which does not
  # generalise to cross targets. For Android the failure is one step further
  # out -- tcl -> tzdata, whose localtime.c collides with bionic's own
  # `timezone_t` typedef. Qt only ever uses libsqlite3.
  sqlite = prev.sqlite.overrideAttrs (old: {
    configureFlags =
      (builtins.filter (f: !(lib.hasPrefix "--with-tcl" f)) (old.configureFlags or [ ]))
      ++ [ "--disable-tcl" ];
  });

  qt6 = prev.qt6.overrideScope (
    qfinal: qprev: {
      # Every Qt repo needs these, not just qtbase: QtBuildHelpers includes
      # QtPlatformAndroid, which requires Java. Miss the toolchain flags and the
      # failure is quiet -- find_package(EGL) fails, no Qt::Gui target exists,
      # and the module configures itself away with a NOTICE.
      qtModule =
        args:
        qprev.qtModule (
          args
          // {
            nativeBuildInputs =
              (args.nativeBuildInputs or [ ]) ++ [ buildPkgs.jdk ] ++ appleAutodetectTools;
            # qtsvg pulls libwebp/libmng/zlib, qtdeclarative pulls openssl: the
            # same DT_NEEDED problem as qtbase, one module further out.
            buildInputs = builtins.filter keepInput (args.buildInputs or [ ]);
            propagatedBuildInputs = builtins.filter keepInput (args.propagatedBuildInputs or [ ]);
            cmakeFlags = (args.cmakeFlags or [ ]) ++ androidQtBuildFlags;

            # QtAndroidHelpers finds this jar under
            # QT_TOOLCHAIN_RELOCATABLE_INSTALL_PREFIX, which only Qt's own
            # toolchain file sets. Its documented override.
            env = (args.env or { }) // {
              QT_ANDROID_JAR_PATH = "${qfinal.qtbase}/jar/Qt6Android.jar";
            };
            # Splitting an Android ELF here buys nothing: androiddeployqt strips
            # what it packages.
            separateDebugInfo = false;
          }
        );

      qtbase =
        let
          base = qprev.qtbase.override {
            # `systemdSupport ? stdenv.hostPlatform.isLinux` defaults to true on
            # Android and drags systemd + journald in.
            systemdSupport = false;
            # `withWayland ? lib.meta.availableOn hostPlatform wayland` is also
            # true, because wayland's meta says linux and Android's kernel is
            # linux.
            withWayland = false;
            cups = null;
            libmysqlclient = null;
            libpq = null;
          };
        in
        base.overrideAttrs (old: {
          # Its NIXPKGS_QT_PLUGIN_PREFIX define arrives via the cc-wrapper, which
          # the NDK toolchain file replaces, so qcoreapplication.cpp stops
          # compiling. A desktop convenience; Android loads plugins from the APK.
          patches = dropPatch "derive-plugin-load-path-from-PATH" (old.patches or [ ]);

          buildInputs = builtins.filter keepInput (old.buildInputs or [ ]);
          propagatedBuildInputs = builtins.filter keepInput (old.propagatedBuildInputs or [ ]);

          # QtPlatformAndroid.cmake does find_package(Java 1.8 COMPONENTS
          # Development REQUIRED) to build Qt's Android Java glue (Qt6Android.jar).
          nativeBuildInputs =
            (old.nativeBuildInputs or [ ]) ++ [ buildPkgs.jdk ] ++ appleAutodetectTools;

          # Later -D flags win on the cmake command line, so appending is enough
          # to beat the ON values the recipe hardcodes.
          cmakeFlags = (old.cmakeFlags or [ ]) ++ androidQtBuildFlags ++ [
            "-DQT_FEATURE_vulkan=OFF"
            "-DQT_FEATURE_libproxy=OFF"
            "-DQT_FEATURE_dbus=OFF"
            "-DQT_FEATURE_glib=OFF"
            "-DQT_FEATURE_icu=OFF"
            "-DQT_FEATURE_fontconfig=OFF"
            # The recipe turns sctp on for every non-Darwin host; bionic has no
            # SCTP stack.
            "-DQT_FEATURE_sctp=OFF"
            # Use Qt's src/3rdparty copies instead of nixpkgs'. See keepForAndroid
            # above for why: every system library here would become a DT_NEEDED
            # soname that nothing on the device can resolve.
            "-DQT_FEATURE_system_zlib=OFF"
            "-DQT_FEATURE_system_pcre2=OFF"
            "-DQT_FEATURE_system_libb2=OFF"
            "-DQT_FEATURE_system_doubleconversion=OFF"
            "-DQT_FEATURE_system_png=OFF"
            "-DQT_FEATURE_system_jpeg=OFF"
            # qtbase has no system_zstd feature -- zstd is either the system one or absent.
            "-DQT_FEATURE_zstd=OFF"
            "-DQT_FEATURE_system_md4c=OFF"
            "-DQT_FEATURE_system_freetype=OFF"
            "-DQT_FEATURE_system_harfbuzz=OFF"
            # nixpkgs hardcodes system_sqlite=ON for every platform.
            "-DQT_FEATURE_system_sqlite=OFF"
            # Qt's own Android builds dlopen libssl at runtime rather than
            # linking it, because the .so has to be bundled per-ABI in the APK.
            # nixpkgs hardcodes openssl_linked=ON for every platform.
            "-DQT_FEATURE_openssl_linked=OFF"
            "-DQT_FEATURE_openssl_runtime=ON"
            "-DQT_ANDROID_ABIS=${abi}"
          ];

          # The upstream postFixup ends with a Linux-only block that patchelfs
          # the mysql SQL driver and links libvulkan into libQt6Gui -- neither
          # plugin nor library exists here. Everything before it still applies.
          postFixup = ''
            moveToOutput      "mkspecs/modules" "$dev"
            fixQtModulePaths  "$dev/mkspecs/modules"
            fixQtBuiltinPaths "$out" '*.pr?'

            substituteInPlace "''${!outputDev}/nix-support/setup-hook" \
              --replace-fail "@qtbaseOut@" $out
          '';

          # separateDebugInfo splits with the build platform's objcopy; the
          # androiddeployqt/gradle path strips the .so it packages anyway.
          separateDebugInfo = false;
        });

      qtdeclarative = addCmakeFlags (
        lib.optionals isCross ([
          "-DQt6QmlTools_DIR=${buildQt.qtdeclarative}/lib/cmake/Qt6QmlTools"
          "-DQt6QuickTools_DIR=${buildQt.qtdeclarative}/lib/cmake/Qt6QuickTools"
          # WITHOUT THIS, QT QUICK IS SILENTLY NOT BUILT AT ALL -- see the
          # Windows overlay for the full story. nixpkgs aims its flag at
          # Qt6ShaderTools (target config) rather than Qt6ShaderToolsTools.
          "-DQt6ShaderToolsTools_DIR=${buildQt.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
        ])
      ) qprev.qtdeclarative;
    }
  );
}
// {
  # CMAKE_TOOLCHAIN_FILE cannot be appended to an existing build tree's flags,
  # so it is a separate attribute from the appendable -D flags. Both are defined
  # unconditionally and empty natively, so a consumer can write them without
  # `or []`.
  logosQtCrossToolchainFile = lib.optionalString isCross androidToolchainFile;

  logosQtCrossCmakeFlags = lib.optionals isCross (
    androidToolchainFlags
    ++ [
      "-DQT_HOST_PATH=${buildQt.qtbase}"
      ("-DQT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH="
        + lib.concatStringsSep ";" (
          map (m: "${buildQt.${m}}") [
            "qtbase"
            "qtdeclarative"
            "qtshadertools"
            "qtsvg"
          ]
        ))
      # Consumed by qt_add_executable/qt_finalize_target to decide which ABIs to
      # package. One ABI in this slice; adding another means adding a whole
      # pseudo-system, not extending this list (see README).
      "-DQT_ANDROID_ABIS=${abi}"
    ]
  );
}

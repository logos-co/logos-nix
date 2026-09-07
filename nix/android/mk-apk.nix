# Package a Qt CMake project as a debug-signed APK for this set's one ABI,
# entirely inside the sandbox: androiddeployqt lays out the gradle project,
# gradle replays ./deps.json, and every shipped .so is checked for DT_NEEDED
# sonames the device cannot resolve.
{
  lib,
  stdenv,
  cmake,
  ninja,
  qt6,
  logosQtHost,
  androidPkgs,
  logosQtCrossCmakeFlags,
  logosQtCrossToolchainFile,
  buildPackages,
}:

{
  pname,
  version,
  src,
  # The qt_add_executable target; androiddeployqt keys its files on it.
  target,
  # Java package name, the same string as the target's QT_ANDROID_PACKAGE_NAME.
  packageName,
  abi ? androidPkgs.abi,
  # Qt modules the app links; merged into the one prefix androiddeployqt reads.
  qtModules ? [ qt6.qtbase qt6.qtdeclarative qt6.qtsvg ],
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  cmakeFlags ? [ ],
  meta ? { },
}:

# One ABI is one cross set: the NDK triple and every Qt library are per-ABI.
assert lib.assertMsg (abi == androidPkgs.abi)
  "mkQtAndroidApk: this package set targets ${androidPkgs.abi}, not ${abi}";

let
  # callPackage splices arguments to the HOST platform, so a plain `gradle_9`
  # argument would be a gradle cross-compiled to bionic (and `gradle.fetchDeps`
  # would drag a target python3 and tzdata into the update script).
  gradle = buildPackages.gradle_9;
  jdk = buildPackages.jdk;
  buildTools = "${androidPkgs.sdkRoot}/build-tools/${androidPkgs.buildToolsVersion}";
in
stdenv.mkDerivation (finalAttrs: {
  inherit pname version src;

  nativeBuildInputs = [
    cmake
    ninja
    gradle
    jdk
  ]
  ++ nativeBuildInputs;

  buildInputs = qtModules ++ buildInputs;

  cmakeFlags = logosQtCrossCmakeFlags ++ [
    "-DCMAKE_TOOLCHAIN_FILE=${logosQtCrossToolchainFile}"
    "-GNinja"
  ]
  ++ cmakeFlags;

  # gradle is driven from buildPhase, inside the directory androiddeployqt
  # generates -- there is no gradle project on disk before that.
  dontUseGradleBuild = true;
  dontUseGradleCheck = true;

  gradleFlags = [
    "-Dorg.gradle.java.home=${jdk}"
    # Maven's aapt2 artifact is per-build-platform and would tie deps.json to
    # one of them; the SDK ships the same tool.
    "-Pandroid.aapt2FromMavenOverride=${buildTools}/aapt2"
    # Fail loudly instead of trying to install SDK components into the store.
    "-Pandroid.builder.sdkDownload=false"
    # AGP's default debug config reads `user.home` from the passwd entry, not
    # $HOME, so in the sandbox it would silently generate a fresh key per build.
    "-Pandroid.injected.signing.store.file=${./debug.keystore}"
    "-Pandroid.injected.signing.store.password=android"
    "-Pandroid.injected.signing.key.alias=androiddebugkey"
    "-Pandroid.injected.signing.key.password=android"
  ];

  # nixpkgs' default nixDownloadDeps resolves every configuration, and under
  # AGP 9 :debugAndroidTestCompileClasspath is ambiguous and aborts.
  gradleUpdateTask = "assembleDebug";

  # The lock is for Qt's gradle template, not the app, so one file serves every
  # consumer. Regenerate from the repo root with any consumer's
  # `.mitmCache.updateScript`; the store-relative path resolves to nix/android/deps.json.
  mitmCache = gradle.fetchDeps {
    pkg = finalAttrs.finalPackage;
    data = ./deps.json;
    # The update script binds only /nix, /tmp, /proc and /dev; make and ninja
    # both run through /bin/sh.
    bwrapFlags = ''--ro-bind "$PWD" "$PWD" --ro-bind ${buildPackages.bash}/bin/sh /bin/sh'';
  };

  preBuild = ''
    cmake --build . --target ${target}_prepare_apk_dir

    # androiddeployqt assumes ONE writable Qt prefix: split store paths hide
    # QtQuick from qmlimportscanner, and a read-only one fails to rewrite
    # res/values/libs.xml and ships an APK with no Qt libraries registered.
    qtPrefix="$NIX_BUILD_TOP/qt-android-prefix"
    mkdir -p "$qtPrefix"
    settings=android-${target}-deployment-settings.json
    for m in ${lib.escapeShellArgs (map toString qtModules)}; do
      cp -r "$m"/. "$qtPrefix"/
      chmod -R u+w "$qtPrefix"
      substituteInPlace "$settings" --replace-quiet "$m" "$qtPrefix"
    done
    grep -q "$qtPrefix" "$settings" || {
      echo "mkQtAndroidApk: $settings references none of qtModules" >&2
      exit 1
    }
    # a target Qt module missing from qtModules would keep a read-only store
    # path here and fail silently later; host-tool paths are allowed to stay
    if grep -E -o '/nix/store/[a-z0-9]{32}-qt[a-z0-9]*-aarch64-unknown-linux-android[^"]*' "$settings"; then
      echo "mkQtAndroidApk: target Qt paths above are not in qtModules" >&2
      exit 1
    fi

    # --aux-mode stops after the gradle project is laid out; without it the
    # tool shells out to gradlew, which downloads a gradle distribution.
    ${logosQtHost.qtbase}/bin/androiddeployqt \
      --input "$settings" \
      --output "$PWD/android-build" \
      --android-platform android-${androidPkgs.compileSdkVersion} \
      --jdk ${jdk} \
      --aux-mode

    # --aux-mode also skips the step that writes these; Qt's build.gradle
    # template reads every key.
    cat > android-build/gradle.properties <<EOF
    buildDir=build
    qtAndroidDir=$qtPrefix/src/android/java
    qt5AndroidDir=$qtPrefix/src/android/java
    androidPackageName=${packageName}
    androidCompileSdkVersion=android-${androidPkgs.compileSdkVersion}
    androidBuildToolsVersion=${androidPkgs.buildToolsVersion}
    androidNdkVersion=${androidPkgs.ndkVersion}
    qtMinSdkVersion=${androidPkgs.apiLevel}
    qtTargetSdkVersion=${androidPkgs.compileSdkVersion}
    qtTargetAbiList=${abi}
    qtGradlePluginType=com.android.application
    legacyPackaging=false
    EOF
    echo "sdk.dir=${androidPkgs.sdkRoot}" > android-build/local.properties

    # The JVM derives user.home from the passwd entry, which on a darwin build
    # platform is the unwritable /var/empty; AGP creates .android under it.
    export HOME="$NIX_BUILD_TOP/home"
    mkdir -p "$HOME/.android"
    gradleFlagsArray+=(-Duser.home="$HOME")
  '';

  preGradleUpdate = "cd android-build";

  buildPhase = ''
    runHook preBuild

    pushd android-build
    gradle assembleDebug
    popd

    runHook postBuild
  '';

  # A DT_NEEDED that is neither packaged nor an NDK stub library for this API
  # level fails the build, not the device (measured: UnsatisfiedLinkError on
  # libb2.so on a real phone). Link-time sonames only; dlopen is out of scope.
  postBuild = ''
    pushd android-build/libs/${abi}

    printf '%s\n' *.so | sort -u > "$NIX_BUILD_TOP/packaged.txt"
    ls ${androidPkgs.ndkStubLibDir}/*.so | xargs -n1 basename | sort -u \
      > "$NIX_BUILD_TOP/android.txt"
    # An empty allowlist would pass everything.
    [ -s "$NIX_BUILD_TOP/android.txt" ] || {
      echo "mkQtAndroidApk: no NDK stub libraries under ${androidPkgs.ndkStubLibDir}" >&2
      exit 1
    }
    sort -u "$NIX_BUILD_TOP/packaged.txt" "$NIX_BUILD_TOP/android.txt" \
      > "$NIX_BUILD_TOP/allowed.txt"

    ${androidPkgs.ndkToolchainBin}/llvm-readelf -d ./*.so \
      | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p' \
      | sort -u > "$NIX_BUILD_TOP/needed.txt"

    if ! foreign=$(comm -23 "$NIX_BUILD_TOP/needed.txt" "$NIX_BUILD_TOP/allowed.txt") \
       || [ -n "$foreign" ]; then
      echo "mkQtAndroidApk: these DT_NEEDED sonames are neither in the APK nor" >&2
      echo "provided by Android at API ${androidPkgs.apiLevel}:" >&2
      printf '  %s\n' $foreign >&2
      exit 1
    fi
    echo "mkQtAndroidApk: $(wc -l < "$NIX_BUILD_TOP/needed.txt") DT_NEEDED sonames, all resolvable on device"

    popd
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp android-build/build/outputs/apk/debug/*-debug.apk "$out/${finalAttrs.passthru.apkName}"

    runHook postInstall
  '';

  dontWrapQtApps = true;

  passthru = {
    inherit target packageName abi;
    apkName = "${pname}-${version}.apk";
  };

  meta = {
    platforms = lib.platforms.aarch64 ++ lib.platforms.arm;
  }
  // meta;
})

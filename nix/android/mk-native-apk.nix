# A Java-free APK around native code: android.app.NativeActivity loads `libName`
# from the APK's native library directory, so the APK holds a manifest and
# lib/<abi>/*.so and nothing else. No Gradle and no Qt.
#
# Every file under lib/<abi>/ must be named lib*.so: the package manager
# extracts nothing else. Executables the app spawns go in the same way
# (lib<name>.so), and the manifest sets extractNativeLibs so they exist on disk.
{
  lib,
  runCommand,
  buildPackages,
  androidPkgs,
}:

{
  pname,
  version,
  # Java package name, e.g. "co.logos.coredemo".
  packageName,
  # The NativeActivity's library, without "lib" and ".so".
  libName,
  label ? pname,
  # A directory whose *.so files become lib/<abi>/; a list of such directories
  # is merged in order.
  libDirs,
  permissions ? [ "android.permission.INTERNET" ],
  minSdk ? androidPkgs.apiLevel,
  targetSdk ? androidPkgs.compileSdkVersion,
  # Extra <intent-filter> XML for the activity (e.g. a URI scheme).
  intentFilters ? "",
  versionCode ? 1,
}:

let
  abi = androidPkgs.abi;
  buildTools = "${androidPkgs.sdkRoot}/build-tools/${androidPkgs.buildToolsVersion}";
  androidJar = "${androidPkgs.sdkRoot}/platforms/android-${androidPkgs.compileSdkVersion}/android.jar";
  manifest = builtins.toFile "AndroidManifest.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <manifest xmlns:android="http://schemas.android.com/apk/res/android"
        package="${packageName}"
        android:versionCode="${toString versionCode}"
        android:versionName="${version}">
      <uses-sdk android:minSdkVersion="${toString minSdk}" android:targetSdkVersion="${toString targetSdk}"/>
    ${lib.concatMapStrings (p: "  <uses-permission android:name=\"${p}\"/>\n") permissions}
      <application android:label="${label}" android:hasCode="false"
          android:extractNativeLibs="true" android:debuggable="true">
        <activity android:name="android.app.NativeActivity" android:exported="true"
            android:configChanges="orientation|screenSize|screenLayout|keyboardHidden|keyboard|uiMode"
            android:windowSoftInputMode="adjustResize">
          <meta-data android:name="android.app.lib_name" android:value="${libName}"/>
          <intent-filter>
            <action android:name="android.intent.action.MAIN"/>
            <category android:name="android.intent.category.LAUNCHER"/>
          </intent-filter>
          ${intentFilters}
        </activity>
      </application>
    </manifest>
  '';
in
runCommand "${pname}-${version}.apk"
  {
    nativeBuildInputs = [ buildPackages.zip buildPackages.unzip buildPackages.jdk buildPackages.file ];
    passthru = { inherit packageName libName abi; apkName = "${pname}-${version}.apk"; };
  }
  ''
    work=$(mktemp -d)
    mkdir -p "$work/apk/lib/${abi}"
    for dir in ${lib.escapeShellArgs (map toString (lib.toList libDirs))}; do
      for so in "$dir"/*.so; do
        cp -L "$so" "$work/apk/lib/${abi}/"
      done
    done
    chmod -R u+w "$work/apk"
    libs="$work/apk/lib/${abi}"
    [ -e "$libs/lib${libName}.so" ] || { echo "no lib${libName}.so among the libraries" >&2; exit 1; }

    # Gate: every DT_NEEDED is packaged or is a library Android provides at minSdk.
    readelf=${androidPkgs.ndkToolchainBin}/llvm-readelf
    ls "$libs" | sort -u > "$work/packaged.txt"
    ls ${androidPkgs.ndkStubLibDir}/*.so | xargs -n1 basename | sort -u > "$work/android.txt"
    [ -s "$work/android.txt" ] || { echo "no NDK stub libraries" >&2; exit 1; }
    sort -u "$work/packaged.txt" "$work/android.txt" > "$work/allowed.txt"
    $readelf -d "$libs"/*.so | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p' | sort -u > "$work/needed.txt"
    foreign=$(comm -23 "$work/needed.txt" "$work/allowed.txt")
    if [ -n "$foreign" ]; then
      echo "these DT_NEEDED sonames are neither packaged nor provided by Android ${toString minSdk}:" >&2
      printf '  %s\n' $foreign >&2
      exit 1
    fi
    # Gate: nothing points back into the build machine's store.
    if grep -l '/nix/store/' "$libs"/*.so; then
      echo "the libraries above still reference /nix/store (RUNPATH or strings)" >&2
      exit 1
    fi
    # Gate: 16 KB pages (Android 15+ devices may use them).
    for so in "$libs"/*.so; do
      if $readelf -lW "$so" | awk '$1 == "LOAD" && strtonum($NF) < 16384 { bad = 1 } END { exit !bad }'; then
        echo "$(basename "$so"): a LOAD segment is aligned below 16 KB" >&2
        exit 1
      fi
    done

    ${buildTools}/aapt2 link -o "$work/base.apk" -I ${androidJar} --manifest ${manifest} \
      --min-sdk-version ${toString minSdk} --target-sdk-version ${toString targetSdk}
    (cd "$work/apk" && zip -q -r "$work/base.apk" lib)
    ${buildTools}/zipalign -P 16 -f 4 "$work/base.apk" "$work/aligned.apk"
    export HOME=$work
    ${buildTools}/apksigner sign --ks ${./debug.keystore} --ks-pass pass:android \
      --key-pass pass:android --ks-key-alias androiddebugkey \
      --out "$out" "$work/aligned.apk"
    ${buildTools}/apksigner verify "$out"
  ''

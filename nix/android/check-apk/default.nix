# Smallest consumer of mkQtAndroidApk: one Window, no content. Exists so
# checks.x86_64-linux.android-apk exercises the packaging path, QML included.
{ lib, mkQtAndroidApk }:

mkQtAndroidApk {
  pname = "logos-apk-check";
  version = "0.1";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./CMakeLists.txt
      ./main.cpp
      ./Main.qml
    ];
  };
  target = "logos_apk_check";
  packageName = "io.logos.apkcheck";
}

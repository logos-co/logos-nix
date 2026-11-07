# Xcode from /Applications, reachable from a nix build. `__noChroot` because
# the iPhone SDK cannot be redistributed into the store. The
# declared version and build are in the derivation name, so every dependent
# hash changes with them; the plist check fails when the installed Xcode differs.
{
  lib,
  stdenvNoCC,
  xcodeVersion, # CFBundleShortVersionString, e.g. "26.6"
  xcodeBuild, # ProductBuildVersion, e.g. "17F113"
  xcodeBaseDir ? "/Applications/Xcode.app",
}:

let
  developerDir = "${xcodeBaseDir}/Contents/Developer";
  toolchainBin = "${developerDir}/Toolchains/XcodeDefault.xctoolchain/usr/bin";

  # Sourced by the wrapper's own build and, via setup-hook, by every build that
  # lists it in nativeBuildInputs, so a cached wrapper cannot outlive its Xcode.
  versionGate = ''
    _plist="${xcodeBaseDir}/Contents/version.plist"
    _installed="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$_plist" 2>/dev/null || true)"
    _installed="$_installed ($(/usr/bin/plutil -extract ProductBuildVersion raw "$_plist" 2>/dev/null || true))"
    if [ "$_installed" != "${xcodeVersion} (${xcodeBuild})" ]; then
      echo "xcode-wrapper: declared Xcode ${xcodeVersion} (${xcodeBuild}), but ${xcodeBaseDir} is Xcode $_installed" >&2
      echo "xcode-wrapper: evaluate with --impure to use the installed Xcode" >&2
      exit 1
    fi
    export DEVELOPER_DIR="${developerDir}"
  '';
in
stdenvNoCC.mkDerivation {
  pname = "xcode-wrapper";
  version = "${xcodeVersion}-${xcodeBuild}";

  __noChroot = true;
  dontUnpack = true;
  preferLocalBuild = true;
  allowSubstitutes = false;

  passthru = {
    inherit
      xcodeVersion
      xcodeBuild
      xcodeBaseDir
      developerDir
      versionGate
      ;
  };

  buildCommand = ''
    ${versionGate}
    mkdir -p "$out/bin" "$out/nix-support"
    ln -s "${developerDir}/usr/bin/xcodebuild" "$out/bin/xcodebuild"
    for tool in clang clang++ ar ranlib libtool lipo strip nm otool install_name_tool dsymutil; do
      ln -s "${toolchainBin}/$tool" "$out/bin/$tool"
    done
    # /usr/bin shims; they follow DEVELOPER_DIR, which the setup-hook pins.
    ln -s /usr/bin/xcrun /usr/bin/xcode-select /usr/bin/codesign /usr/bin/plutil /usr/bin/security "$out/bin/"
    cat > "$out/nix-support/setup-hook" <<'EOF'
    ${versionGate}
    EOF
  '';

  meta = {
    description = "Version-gated symlinks into the installed Xcode ${xcodeVersion} (${xcodeBuild})";
    platforms = lib.platforms.darwin;
  };
}

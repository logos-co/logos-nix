#!/usr/bin/env bash
# Mutation test for checks.<system>.import-cargo-lock-overlay.
#
# A drift gate that has quietly stopped discriminating is the same silent
# failure it was written to catch. Each case below replays a real defect and
# asserts rejection BY MESSAGE -- a status-only test would pass on a syntax
# error too.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gate-mutations.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

OVERLAY=nix/overlays/import-cargo-lock-static-crates-io.nix
failures=0
DIR=

# Fetch the locked inputs once rather than per copy.
nix flake archive --no-write-lock-file "$ROOT" >/dev/null || exit 1

prepare() {
  DIR="$WORK/$1"
  cp -R "$ROOT" "$DIR" || exit 1
  rm -rf "$DIR/.git"
  git -C "$DIR" init -q || exit 1   # a flake only sees git-tracked files
}

# Replace the line whose trimmed text is exactly $2 with $3 ("\n" allowed).
# Exact rather than substring so a rename cannot leave the anchor still
# matching; aborts on no match, several matches, or a no-op, because a mutation
# that silently did nothing would pass its case for the wrong reason.
mutate() {
  local file=$1 anchor=$2 repl=$3 n
  n=$(awk -v a="$anchor" '{ l=$0; gsub(/^[ \t]+|[ \t]+$/, "", l); if (l == a) c++ } END { print c+0 }' "$file")
  [ "$n" = 1 ] || { echo "MUTATION ERROR: $n exact-line matches for '$anchor' in $file"; exit 1; }
  awk -v a="$anchor" -v repl="$repl" '
    { l=$0; gsub(/^[ \t]+|[ \t]+$/, "", l) }
    l == a { print repl; next }
    { print }' "$file" > "$file.mut" || exit 1
  cmp -s "$file" "$file.mut" && { echo "MUTATION ERROR: no-op on $file"; exit 1; }
  mv "$file.mut" "$file"
}

# Drop the one bare `name` line from a Nix list.
drop_list_entry() {
  local file=$1 name=$2
  awk -v n="$name" '!($1 == n && NF == 1)' "$file" > "$file.mut" || exit 1
  cmp -s "$file" "$file.mut" && { echo "MUTATION ERROR: no bare '$name' entry in $file"; exit 1; }
  mv "$file.mut" "$file"
}

check() { ( cd "$DIR" && git add -A && nix flake check --no-build 2>&1 ); }

expect_fail() { # name message
  local name=$1 msg=$2 out rc
  out=$(check); rc=$?
  if [ $rc -eq 0 ]; then
    echo "FAIL  $name: gate PASSED a known-bad tree"; failures=$((failures + 1))
  elif ! printf '%s\n' "$out" | grep -qF -- "$msg"; then
    echo "FAIL  $name: failed, but not with \"$msg\""; printf '%s\n' "$out" | tail -25
    failures=$((failures + 1))
  else
    echo "ok    $name -- caught: $msg"
  fi
}

expect_pass() {
  local name=$1 out rc
  out=$(check); rc=$?
  if [ $rc -ne 0 ]; then
    echo "FAIL  $name: clean tree rejected"; printf '%s\n' "$out" | tail -25
    failures=$((failures + 1))
  else
    echo "ok    $name"
  fi
}

# M1 -- the overlay as merged in #9: a fresh callPackage rebuilds the argument
# set, so the rustPlatform's own cargo never reaches importCargoLock.
prepare m1
mutate "$DIR/$OVERLAY" "importCargoLock = rprev.importCargoLock.override { fetchurl = cdnFetchurl; };" \
  "          importCargoLock = final.callPackage importCargoLockFile { fetchurl = cdnFetchurl; };"
expect_fail "M1 callPackage drops cargo" "cargo never reaches importCargoLock"

# M2 -- cargo threaded through, but `final` is the HOST set, so under cross the
# vendor dir moves and its git-crate script runs target cargo/jq.
prepare m2
mutate "$DIR/$OVERLAY" "importCargoLock = rprev.importCargoLock.override { fetchurl = cdnFetchurl; };" \
  "          importCargoLock = final.callPackage importCargoLockFile {\n            inherit (args) cargo;\n            fetchurl = cdnFetchurl;\n          };"
expect_fail "M2 wrong platform placement" "not instantiated on the build platform"

# M3 -- rewrite still fires but lands somewhere that is not the CDN.
prepare m3
mutate "$DIR/$OVERLAY" 'cdnPrefix = "https://static.crates.io/crates";' \
  '  cdnPrefix = "https://mirror.invalid/crates";'
expect_fail "M3 rewrite targets the wrong host" \
  "crate not on the CDN (https://mirror.invalid/crates/"

# M4 -- dropped from nativeOverlays but still listed in lib.overlays: the
# bookkeeping gate names the mistake before any crate URL is looked at.
prepare m4
drop_list_entry "$DIR/flake.nix" importCargoLockStaticCratesIoOverlay
expect_fail "M4 exported but not applied" "overlay export drift"

# M6 -- dropped from both, so the overlay is simply gone and nothing rewrites.
prepare m6
drop_list_entry "$DIR/flake.nix" importCargoLockStaticCratesIoOverlay
mutate "$DIR/flake.nix" "importCargoLockStaticCratesIo = importCargoLockStaticCratesIoOverlay;" ""
expect_fail "M6 overlay not applied" \
  "crate not on the CDN (https://crates.io/api/v1/crates/"

# M5 -- the rewrite matches nothing. Caught by the OVERLAY's own assert, which
# fires before the drift gate is ever reached; kept because that guard is the
# only thing standing between a moved registry default and a silent no-op.
prepare m5
mutate "$DIR/$OVERLAY" 'apiPrefix = "https://crates.io/api/v1/crates";' \
  '  apiPrefix = "https://crates.invalid/nowhere";'
expect_fail "M5 rewrite matches nothing" "references neither"

# M7 -- the fetchCrate rewrite lands somewhere that is not the CDN. Its own
# overlay, its own gate; the exports gate covers forgetting to register it.
prepare m7
mutate "$DIR/nix/overlays/fetch-crate-static-crates-io.nix" \
  'cdnPrefix = "https://static.crates.io/crates";' \
  '  cdnPrefix = "https://mirror.invalid/crates";'
expect_fail "M7 fetchCrate targets the wrong host" \
  "crate source not on the CDN (https://mirror.invalid/crates/"

prepare clean
expect_pass "clean tree passes"

if [ $failures -eq 0 ]; then echo "all mutations caught"; else echo "$failures case(s) failed"; fi
exit $((failures > 0))

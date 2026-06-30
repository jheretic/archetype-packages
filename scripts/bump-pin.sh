#!/usr/bin/env bash
# Bump a package's pinned git revision (_commit) + pkgver to its source repo's
# current HEAD, so the image build stops shipping stale source.
#
# Usage: scripts/bump-pin.sh <miz|archetype-install> [--source-dir PATH]
#
# pkgver is regenerated EXACTLY as the PKGBUILD's pkgver() does
# (<base>.r<count>.g<short12>), reading the base version from the same
# Cargo.toml the PKGBUILD reads. The pinned commit MUST already be pushed to the
# package's GitHub origin -- the PKGBUILD source= clones from there, so an
# unpushed SHA would fail the build; this script refuses to pin an unpushed
# commit.

set -euo pipefail

PKG="${1:-}"
case "$PKG" in
  miz)
    SRC_DEFAULT="$HOME/src/archetype/miz"
    CARGO_TOML="crates/miz/Cargo.toml"   # workspace member, per miz's pkgver()
    ;;
  archetype-install)
    SRC_DEFAULT="$HOME/src/archetype/archetype-install"
    CARGO_TOML="Cargo.toml"
    ;;
  *)
    echo "usage: $0 <miz|archetype-install> [--source-dir PATH]" >&2
    exit 2
    ;;
esac

SRC="$SRC_DEFAULT"
if [ "${2:-}" = "--source-dir" ]; then
  SRC="${3:?--source-dir needs a path}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKGBUILD="$SCRIPT_DIR/../packages/$PKG/PKGBUILD"

[ -d "$SRC/.git" ] || { echo "bump-pin: $SRC is not a git repo" >&2; exit 1; }
[ -f "$PKGBUILD" ]  || { echo "bump-pin: no PKGBUILD at $PKGBUILD" >&2; exit 1; }
[ -f "$SRC/$CARGO_TOML" ] || { echo "bump-pin: no $CARGO_TOML in $SRC" >&2; exit 1; }

commit="$(git -C "$SRC" rev-parse HEAD)"
short12="$(git -C "$SRC" rev-parse --short=12 HEAD)"
count="$(git -C "$SRC" rev-list --count HEAD)"
base="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$SRC/$CARGO_TOML" | head -1)"
[ -n "$base" ] || { echo "bump-pin: could not read version from $CARGO_TOML" >&2; exit 1; }
pkgver="${base}.r${count}.g${short12}"

# Refuse to pin an unpushed commit: the build clones from origin and would fail.
remote="$(git -C "$SRC" remote get-url origin 2>/dev/null || true)"
[ -n "$remote" ] || { echo "bump-pin: $SRC has no 'origin' remote" >&2; exit 1; }
if ! git -C "$SRC" branch -r --contains "$commit" 2>/dev/null | grep -q .; then
  echo "bump-pin: HEAD ($short12) is not on any remote branch of $remote." >&2
  echo "          Push it first, then re-run. (Refusing to pin an unpushed commit.)" >&2
  exit 1
fi
# Best-effort confirm the remote actually has it (skipped if the remote is
# unreachable, e.g. offline sandbox -- the branch-contains check above already
# guards the common case).
if git -C "$SRC" ls-remote --exit-code origin >/dev/null 2>&1; then
  if ! git -C "$SRC" ls-remote origin | grep -q "^${commit}\b"; then
    echo "bump-pin: WARNING: $commit not found among origin refs (may be on an" >&2
    echo "          unpushed branch tip). Verify it is fetchable before building." >&2
  fi
fi

# Rewrite the two anchored lines in place.
tmp="$(mktemp)"
sed -E \
  -e "s|^_commit=.*|_commit='${commit}'|" \
  -e "s|^pkgver=.*|pkgver=${pkgver}|" \
  "$PKGBUILD" >"$tmp"
mv "$tmp" "$PKGBUILD"

echo "bumped $PKG: _commit=${commit}"
echo "             pkgver=${pkgver}"
echo "(commit the PKGBUILD change in archetype-packages.)"

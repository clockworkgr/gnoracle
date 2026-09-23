#!/usr/bin/env bash
# build:  copy the packages into build/ with the "clockwork" namespace
#         rewritten to $NS (paths, imports, gnomod modules), tests stripped.
# deploy: addpkg every built package that is not live yet, in dependency
#         order, from key $KEY to $REMOTE.
#
#   make build NS=g1lnk...            # inspect build/
#   make deploy NS=g1lnk... REMOTE=https://rpc.gno.land:443 CHAINID=gnoland-1 KEY=deployer
#   WITH_KOURTDEV=1 make deploy ...   # also the stand-in Kourt (dev and test chains only)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=env.sh
. "$here/scripts/env.sh"

SRC_NS="clockwork"
BUILD="$here/build"

# dependency order: pure packages, then realms
PKGS=(
  p/$SRC_NS/gnoracle/jsonw/v0
  p/$SRC_NS/gnoracle/agg/v0
  p/$SRC_NS/gnoracle/rounds/v0
  p/$SRC_NS/gnoracle/tally/v0
  p/$SRC_NS/gnoracle/checkpoint/v0
  p/$SRC_NS/gnoracle/ledger/v0
  p/$SRC_NS/gnoracle/params/v0
  p/$SRC_NS/gnoracle/spec/v0
  r/$SRC_NS/gnoracle/core
  r/$SRC_NS/gnoracle/core/impl/v1
  r/$SRC_NS/gnoracle/token
  r/$SRC_NS/gnoracle/dao
  r/$SRC_NS/gnoracle/dao/impl/v1
  r/$SRC_NS/gnoracle/dao/exec
  r/$SRC_NS/gnoracle/kourt
  r/$SRC_NS/gnoracle/kourt/impl/v1
)
if [ "${WITH_KOURTDEV:-0}" = 1 ]; then
  PKGS=("${PKGS[@]:0:14}" r/$SRC_NS/gnoracle/kourtdev "${PKGS[@]:14}")
fi

# package paths, imports and gnoweb links: /p/clockwork/... and /r/clockwork/...
rewrite() { sed -e "s#/p/$SRC_NS/#/p/$NS/#g" -e "s#/r/$SRC_NS/#/r/$NS/#g"; }

build() {
  rm -rf "$BUILD"
  for p in "${PKGS[@]}"; do
    src="$here/gno.land/$p"
    dst="$BUILD/gno.land/${p/\/$SRC_NS\//\/$NS\/}"
    [ -d "$src" ] || { echo "missing $src" >&2; exit 1; }
    mkdir -p "$dst"
    for f in "$src"/*.gno "$src"/gnomod.toml; do
      [ -e "$f" ] || continue
      case "$f" in *_test.gno|*_filetest.gno) continue;; esac
      rewrite < "$f" > "$dst/$(basename "$f")"
    done
  done
  echo "built $(find "$BUILD" -name gnomod.toml | wc -l | tr -d ' ') packages under $BUILD (namespace $NS)"
  if [ "$NS" != "$SRC_NS" ] && grep -rl "$SRC_NS" "$BUILD" --include='*.gno' | grep -v kourtdev | head -1 >/dev/null; then
    echo "note: the source namespace still appears in:" >&2
    grep -rn "$SRC_NS" "$BUILD" --include='*.gno' | grep -v kourtdev | head -5 >&2
  fi
}

deploy() {
  [ -d "$BUILD" ] || build
  for p in "${PKGS[@]}"; do
    path="gno.land/${p/\/$SRC_NS\//\/$NS\/}"
    dir="$BUILD/$path"
    if pkg_exists "$path"; then
      echo "live: $path"
      continue
    fi
    echo "addpkg: $path"
    tx addpkg -pkgpath "$path" -pkgdir "$dir" -deposit "$ADDPKG_DEPOSIT" -gas-fee "$ADDPKG_GAS_FEE" -gas-wanted "$ADDPKG_GAS_WANTED"
  done
  echo "deployed. Next: Accept the implementations (see docs/OPERATIONS.md §2)."
}

case "${1:-}" in
  build) build;;
  deploy) deploy;;
  *) echo "usage: $0 build|deploy" >&2; exit 2;;
esac

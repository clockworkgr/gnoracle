#!/usr/bin/env bash
# build:  copy the packages into build/ with the "clockwork" namespace
#         rewritten to $NS (paths, imports, gnomod modules), tests stripped.
# deploy: addpkg every built package that is not live yet, in dependency
#         order, from key $KEY to $REMOTE.
#
#   make build NS=g1lnk...            # inspect build/
#   make deploy NS=g1lnk... REMOTE=https://rpc.gno.land:443 CHAINID=gnoland-1 KEY=deployer
#   WITH_KOURTDEV=1 make deploy ...   # also the stand-in Kourt and its release (dev and test chains only)
#
# ADMIN: the sources name the public test1 key (its mnemonic is in
# scripts/dev-keys.sh) as the bootstrap authority of core, dao and kourt and
# as the token's genesis holder, so that gnodev and the tests work unedited.
# The build replaces it with $ADMIN, which defaults to NS when NS is an
# address. deploy refuses a build that still names test1 on any chain other
# than "dev".
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=env.sh
. "$here/scripts/env.sh"

SRC_NS="clockwork"
BUILD="$here/build"
# the Kourt realm the production mirror release is compiled against
KOURT_V3="${KOURT_V3:-gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3}"
# the public test1 key, the bootstrap authority in the sources
TEST1_ADDR="g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
ADMIN="${ADMIN:-}"
if [ -z "$ADMIN" ]; then
  case "$NS" in g1*) ADMIN="$NS";; esac
fi
if [ -n "$ADMIN" ] && ! printf '%s' "$ADMIN" | grep -Eq '^g1[02-9ac-hj-np-z]{38}$'; then
  echo "ADMIN=$ADMIN is not a g1 address" >&2
  exit 2
fi

# dependency order (every package after the ones it imports): the pure
# packages, then core (authspec, params, spec), its release (core, agg, jsonw,
# rounds, spec), token, kourt (authspec), dao (core, kourt, token, checkpoint,
# ledger, params, authspec), the dao release (dao, core, token, tally, jsonw),
# exec (dao) and the mirror release (core, kourt, Kourt v3).
PKGS=(
  p/$SRC_NS/gnoracle/jsonw/v0
  p/$SRC_NS/gnoracle/agg/v0
  p/$SRC_NS/gnoracle/rounds/v0
  p/$SRC_NS/gnoracle/tally/v0
  p/$SRC_NS/gnoracle/checkpoint/v0
  p/$SRC_NS/gnoracle/ledger/v0
  p/$SRC_NS/gnoracle/params/v0
  p/$SRC_NS/gnoracle/spec/v0
  p/$SRC_NS/gnoracle/authspec/v0
  r/$SRC_NS/gnoracle/core
  r/$SRC_NS/gnoracle/core/impl/v1
  r/$SRC_NS/gnoracle/token
  r/$SRC_NS/gnoracle/kourt
  r/$SRC_NS/gnoracle/dao
  r/$SRC_NS/gnoracle/dao/impl/v1
  r/$SRC_NS/gnoracle/dao/exec
  r/$SRC_NS/gnoracle/kourt/impl/kourtv3
)
# kourt/impl/kourtv3 is the production mirror release: it imports the
# deployed Kourt v3 realm (gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3),
# which must exist on the target chain. kourt/impl/v1 binds the stand-in
# court and ships only together with kourtdev under WITH_KOURTDEV=1 (dev and
# test chains). ONLY="path1 path2" restricts a run to some packages
# (relative to gno.land/, source namespace), e.g. a new release.
if [ "${WITH_KOURTDEV:-0}" = 1 ]; then
  PKGS+=(r/$SRC_NS/gnoracle/kourtdev r/$SRC_NS/gnoracle/kourt/impl/v1)
fi
if [ -n "${ONLY:-}" ]; then
  read -r -a PKGS <<< "$ONLY"
fi

# package paths, imports and gnoweb links: /p/clockwork/... and /r/clockwork/...,
# and the test1 bootstrap authority when ADMIN is set
rewrite() {
  if [ -n "$ADMIN" ]; then
    sed -e "s#/p/$SRC_NS/#/p/$NS/#g" -e "s#/r/$SRC_NS/#/r/$NS/#g" -e "s#$TEST1_ADDR#$ADMIN#g"
  else
    sed -e "s#/p/$SRC_NS/#/p/$NS/#g" -e "s#/r/$SRC_NS/#/r/$NS/#g"
  fi
}

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
    if [ "${WITH_KOURTDEV:-0}" != 1 ] && grep -q "gnoracle/kourtdev\"" "$dst"/*.gno 2>/dev/null; then
      echo "build: $p imports the stand-in kourtdev, which this deployment does not ship (WITH_KOURTDEV=1 for dev chains)" >&2
      exit 1
    fi
  done
  echo "built $(find "$BUILD" -name gnomod.toml | wc -l | tr -d ' ') packages under $BUILD (namespace $NS, admin ${ADMIN:-$TEST1_ADDR (test1)})"
  if [ "$NS" != "$SRC_NS" ] && grep -rl "$SRC_NS" "$BUILD" --include='*.gno' | grep -v kourtdev | head -1 >/dev/null; then
    echo "note: the source namespace still appears in:" >&2
    grep -rn "$SRC_NS" "$BUILD" --include='*.gno' | grep -v kourtdev | head -5 >&2
  fi
}

deploy() {
  build # always from the current sources and namespace
  if [ "$CHAINID" != dev ] && grep -rq "$TEST1_ADDR" "$BUILD"; then
    echo "deploy: the build still names the public test1 key ($TEST1_ADDR) as an authority, and its mnemonic is public; set ADMIN=g1... (or use an address namespace) for chain $CHAINID:" >&2
    grep -rln "$TEST1_ADDR" "$BUILD" | sed "s#^$BUILD/#  #" >&2
    exit 1
  fi
  case "$NS" in
    g1*)
      if ! gk list 2>/dev/null | grep -q "addr: $NS\b"; then
        echo "deploy: the namespace $NS is an address and the keybase holds no key for it (KEY=$KEY, GNOKEY_HOME=${GNOKEY_HOME:-default})" >&2
        exit 1
      fi ;;
  esac
  for p in "${PKGS[@]}"; do
    path="gno.land/${p/\/$SRC_NS\//\/$NS\/}"
    dir="$BUILD/$path"
    if pkg_exists "$path"; then
      echo "live: $path"
      continue
    fi
    if [ "$p" = "r/$SRC_NS/gnoracle/kourt/impl/kourtv3" ] && ! pkg_exists "$KOURT_V3"; then
      echo "skip: $path imports $KOURT_V3, which $REMOTE does not have (deploy with WITH_KOURTDEV=1 on chains without Kourt v3)"
      continue
    fi
    echo "addpkg: $path"
    tx addpkg -pkgpath "$path" -pkgdir "$dir" -max-deposit "$ADDPKG_MAX_DEPOSIT" -gas-fee "$ADDPKG_GAS_FEE" -gas-wanted "$ADDPKG_GAS_WANTED"
  done
  echo "deployed. Next: Accept the implementations (see docs/OPERATIONS.md §2)."
}

case "${1:-}" in
  build) build;;
  deploy) deploy;;
  *) echo "usage: $0 build|deploy" >&2; exit 2;;
esac

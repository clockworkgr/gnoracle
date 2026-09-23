#!/usr/bin/env bash
# Populates deps/ with the source of every gno.land package this workspace
# imports, read off the chain in SOURCE_REMOTE (mainnet by default) with
# vm/qfile, transitively. `gno test` and gnodev then resolve exactly the code
# that runs on the chain, regardless of what $GNOROOT/examples or any shared
# download cache contain.
#
# The upgradeable package is on mainnet under the deployer's address
# namespace; it is mirrored under the "clockwork" source namespace with its
# module path rewritten, and `make build` rewrites it back (see deploy.sh).
#
#   SOURCE_REMOTE=https://rpc.pearl.testnets.gno.land:443 make deps
#   FORCE=1 make deps        # re-fetch everything
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gnokey="${GNOKEY:-gnokey}"
source_remote="${SOURCE_REMOTE:-https://rpc.gno.land:443}"
if ! command -v "$gnokey" >/dev/null 2>&1; then
  echo "deps: gnokey not found at '$gnokey' (run make toolchain, or set GNOKEY)" >&2
  exit 1
fi
addr_ns="g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm"
own_p="gno.land/p/clockwork/gnoracle/"   # packages of this workspace: never fetched
own_r="gno.land/r/clockwork/gnoracle/"

if [ "${FORCE:-}" = 1 ] && [ -d "$here/deps" ]; then
  # keep the old mirror until the new one is complete
  rm -rf "$here/deps.old"; mv "$here/deps" "$here/deps.old"
  trap 'if [ -d "$here/deps.old" ]; then rm -rf "$here/deps"; mv "$here/deps.old" "$here/deps"; echo "deps: refetch failed; previous mirror restored" >&2; fi' EXIT
fi

# qfile prints a package's file list or a file's content; a failed query
# (unknown package, unreachable remote) prints the node's message and fails.
qfile() {
  local out
  if ! out="$("$gnokey" query vm/qfile -data "$1" -remote "$source_remote" 2>&1)"; then
    echo "deps: query $1 on $source_remote failed: $(printf '%s' "$out" | head -3 | tr '\n' ' ')" >&2
    return 1
  fi
  printf '%s\n' "$out" | sed '1d; s/^data: //'
}

# fetch_pkg <import path> [<on-chain path>]: mirror one package.
fetch_pkg() {
  local p="$1" src="${2:-$1}" d="$here/deps/$1" files f
  files="$(qfile "$src")" || true
  if [ -z "$files" ]; then
    echo "deps: $src is not on $source_remote" >&2
    return 1
  fi
  # fetch into a temporary directory and move it into place only when every
  # file arrived, so an interrupted run never leaves a half package that a
  # later run takes for complete
  local tmp="$d.tmp"
  rm -rf "$tmp"; mkdir -p "$tmp"
  for f in $files; do
    case "$f" in
      *_test.gno|*_filetest.gno) continue ;;
      *.gno|gnomod.toml|README.md) qfile "$src/$f" > "$tmp/$f" ;;
    esac
  done
  if [ "$src" != "$p" ]; then
    # portable in-place rewrite (BSD and GNU sed disagree on -i)
    for f in "$tmp"/*.gno "$tmp/gnomod.toml"; do
      sed -e "s#$src#$p#g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
  fi
  rm -rf "$d"; mkdir -p "$(dirname "$d")"; mv "$tmp" "$d"
  echo "deps: $p <- $source_remote${2:+ ($2)}"
}

# imports lists every gno.land import spec under gno.land/ and deps/.
imports() {
  find "$here/gno.land" "$here/deps" -name '*.gno' -print0 2>/dev/null |
    xargs -0 grep -hE '^[[:space:]]*(import[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*[[:space:]]+)?"gno\.land/[pr]/[^"]+"[[:space:]]*$' |
    sed -E 's/.*"(gno\.land\/[^"]+)".*/\1/' | sort -u
}

# EXTRA lists import paths to mirror even before any source imports them
# (space-separated), e.g. EXTRA="gno.land/p/clockwork/upgradeable/v0" make deps
for p in ${EXTRA:-}; do
  [ -f "$here/deps/$p/gnomod.toml" ] && continue
  case "$p" in
    gno.land/p/clockwork/upgradeable/v0|gno.land/p/clockwork/app/v0)
      fetch_pkg "$p" "gno.land/p/$addr_ns/${p#gno.land/p/clockwork/}" ;;
    *) fetch_pkg "$p" ;;
  esac
done

changed=1
while [ "$changed" = 1 ]; do
  changed=0
  for p in $(imports); do
    case "$p" in "$own_p"*|"$own_r"*) continue ;; esac
    [ -f "$here/deps/$p/gnomod.toml" ] && continue
    case "$p" in
      gno.land/p/clockwork/upgradeable/v0|gno.land/p/clockwork/app/v0)
        fetch_pkg "$p" "gno.land/p/$addr_ns/${p#gno.land/p/clockwork/}" ;;
      *) fetch_pkg "$p" ;;
    esac
    changed=1
  done
done
rm -rf "$here/deps.old"; trap - EXIT
echo "deps: up to date ($(find "$here/deps" -name gnomod.toml 2>/dev/null | wc -l | tr -d ' ') packages)"

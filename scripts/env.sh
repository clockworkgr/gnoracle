#!/usr/bin/env bash
# Shared settings for the scripts. Every value can be overridden from the
# environment or the make command line, e.g. `make deploy NS=nym-clockwork001`.

NS="${NS:-g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm}"   # namespace: the deployer address (plan §16)
PKG="${PKG:-gno.land/r/$NS/gnoracle/core}"              # the permanent core realm
DAO_PKG="${DAO_PKG:-gno.land/r/$NS/gnoracle/dao}"
TOKEN_PKG="${TOKEN_PKG:-gno.land/r/$NS/gnoracle/token}"
KOURT_PKG="${KOURT_PKG:-gno.land/r/$NS/gnoracle/kourt}"
UPGRADEABLE_PKG="${UPGRADEABLE_PKG:-gno.land/p/$NS/upgradeable/v0}"

REMOTE="${REMOTE:-http://127.0.0.1:26657}"  # gnodev by default
CHAINID="${CHAINID:-dev}"
KEY="${KEY:-test1}"                         # key name or address in the keybase
GNOKEY="${GNOKEY:-gnokey}"
# The Makefile exports GNOHOME=<repo>/.gnohome for the gno download cache, and
# gnokey's default keybase follows GNOHOME too; point at the user's real
# keybase unless the caller chose one.
if [ -z "${GNOKEY_HOME:-}" ] && [ -n "${GNOHOME:-}" ]; then
  GNOKEY_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/gno"
fi
GNOKEY_HOME="${GNOKEY_HOME:-}"              # empty: gnokey's default keybase

# Gas. gno.land accepts a fee/gas ratio of 0.001 ugnot/gas or more; these
# offer 0.002. gas-wanted is a ceiling and a ceiling is not charged, the fee
# is deducted in full. Storage locks 100ugnot per byte and is refundable, so
# the deposit ceiling costs nothing.
# Realm calls: ProposeFeed simulates at about 38M gas, Submit at 18M, a
# finalising Submit at 32M; 60M is a safe ceiling (only the fee is charged).
CALL_GAS_WANTED="${CALL_GAS_WANTED:-60000000}"
CALL_GAS_FEE="${CALL_GAS_FEE:-120000ugnot}"
# addpkg: the permanent core realm simulates at about 152M gas and locks a
# storage deposit of about 32 GNOT (refundable); the whole set needs roughly
# 150 GNOT of deposits plus fees on the deployer key.
ADDPKG_GAS_WANTED="${ADDPKG_GAS_WANTED:-250000000}"
ADDPKG_GAS_FEE="${ADDPKG_GAS_FEE:-500000ugnot}"
ADDPKG_MAX_DEPOSIT="${ADDPKG_MAX_DEPOSIT:-${ADDPKG_DEPOSIT:-50000000ugnot}}"

# gk runs gnokey with the keybase location applied.
gk() {
  local sub="$1"; shift
  if [ "$sub" = maketx ]; then
    local kind="$1"; shift
    if [ -n "$GNOKEY_HOME" ]; then
      "$GNOKEY" maketx "$kind" -home "$GNOKEY_HOME" "$@"
    else
      "$GNOKEY" maketx "$kind" "$@"
    fi
    return
  fi
  if [ -n "$GNOKEY_HOME" ]; then
    "$GNOKEY" "$sub" -home "$GNOKEY_HOME" "$@"
  else
    "$GNOKEY" "$sub" "$@"
  fi
}

# tx signs and broadcasts one transaction. The password is asked once per
# run and reused for the following transactions of the same run (handed to
# gnokey on stdin, never written anywhere). GNOKEY_PASSWORD skips the prompt;
# do that only for a throwaway dev key.
tx() {
  local kind="$1"; shift
  if [ -z "${GNOKEY_PASSWORD:-}" ] && [ -t 0 ]; then
    printf 'password for %s: ' "$KEY" >&2
    IFS= read -rs GNOKEY_PASSWORD
    printf '\n' >&2
    # kept in this shell only (the pipe below delivers it); never exported
  fi
  if [ -n "${GNOKEY_PASSWORD:-}" ]; then
    printf '%s\n' "$GNOKEY_PASSWORD" |
      gk maketx "$kind" "$@" -broadcast -chainid "$CHAINID" -remote "$REMOTE" -insecure-password-stdin "$KEY"
  else
    gk maketx "$kind" "$@" -broadcast -chainid "$CHAINID" -remote "$REMOTE" "$KEY"
  fi
}

# call runs one function on a realm: call <pkgpath> <fn> [args...]
call() {
  local pkg="$1" fn="$2"; shift 2
  local args=()
  for a in "$@"; do args+=(-args "$a"); done
  tx call -pkgpath "$pkg" -func "$fn" "${args[@]}" -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED"
}

# qrender returns Render(path) of a realm as plain text: qrender <pkgpath> <path>
qrender() {
  gk query vm/qrender -data "$1:$2" -remote "$REMOTE" | sed '1d; s/^data: //'
}

# pkg_exists reports whether a package is live on the remote.
pkg_exists() {
  gk query vm/qfile -data "$1/gnomod.toml" -remote "$REMOTE" >/dev/null 2>&1
}

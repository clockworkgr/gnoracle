#!/usr/bin/env bash
# Creates a throwaway keybase in .dev-keys/ holding test1, the public gnodev
# account that funds itself at genesis. Never use it for anything real.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
home="$here/.dev-keys"
mnemonic="source bonus chronic canvas draft south burst lottery vacant surface solve popular case indicate oppose farm nothing bullet exhibit title speed wink action roast"
if "${GNOKEY:-gnokey}" list -home "$home" 2>/dev/null | grep -q ' test1 '; then
  echo "dev-keys: test1 already in $home"
  exit 0
fi
mkdir -p "$home"
printf '%s\n%s\n%s\n' "$mnemonic" "${GNOKEY_PASSWORD:-devpassword}" "${GNOKEY_PASSWORD:-devpassword}" |
  "${GNOKEY:-gnokey}" add -home "$home" -recover -insecure-password-stdin test1 >/dev/null
echo "dev-keys: test1 (g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5) in $home"

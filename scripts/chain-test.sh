#!/usr/bin/env bash
# Drives a running gnodev (make dev) through a feed lifecycle with real
# transactions: accept the implementation, propose and activate a one-minute
# price feed, bond two providers, submit, finalise, deposit credit and read.
# Uses the throwaway test1 key in .dev-keys (make dev-keys) and a second key
# it funds. Prints each step; exits non-zero on the first failure.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# gnodev serves the workspace source, whose namespace is "clockwork" regardless
# of the deployment NS the Makefile exports.
export NS="${DEV_NS:-clockwork}"
export REMOTE="${REMOTE:-http://127.0.0.1:26657}"
export CHAINID="${CHAINID:-dev}"
export GNOKEY="${GNOKEY:-$HOME/.cache/gno-toolchains/v1.2.0/gnokey}"
export GNOKEY_HOME="${GNOKEY_HOME:-$here/.dev-keys}"
export GNOKEY_PASSWORD="${GNOKEY_PASSWORD:-devpassword}"
export KEY="${KEY:-test1}"
# shellcheck source=env.sh
. "$here/scripts/env.sh"

CORE="gno.land/r/$NS/gnoracle/core"
IMPL="$CORE/impl/v1"
TEST1=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5

step() { printf '\n== %s\n' "$*"; }
qeval() { gk query vm/qeval -data "$1" -remote "$REMOTE" | sed '1d; s/^data: //'; }
send_call() { # key fn send args...
  local key="$1" fn="$2" send="$3"; shift 3
  local args=()
  for a in "$@"; do args+=(-args "$a"); done
  KEY="$key" tx call -pkgpath "$CORE" -func "$fn" "${args[@]}" -send "$send" -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
}
plain_call() { # key fn args...
  local key="$1" fn="$2"; shift 2
  local args=()
  for a in "$@"; do args+=(-args "$a"); done
  KEY="$key" tx call -pkgpath "$CORE" -func "$fn" "${args[@]}" -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
}

"$here/scripts/dev-keys.sh" >/dev/null
if ! gk list 2>/dev/null | grep -q ' prov2 '; then
  step "creating a second key (prov2)"
  printf '%s\n%s\n' "$GNOKEY_PASSWORD" "$GNOKEY_PASSWORD" | gk add -insecure-password-stdin prov2 >/dev/null
fi
PROV2="$(gk list 2>/dev/null | grep -A1 'prov2' | grep -oE 'g1[0-9a-z]{38}' | head -1)"
[ -n "$PROV2" ] || { echo "could not read prov2 address" >&2; exit 1; }

step "state before"
echo "live: $(qeval "$CORE.LivePath()")"
echo "pending: $(qeval "$CORE.PendingPaths()")"

if [ "$(qeval "$CORE.LivePath()")" != "(\"$IMPL\" string)" ]; then
  step "accept the implementation (registered by its own init at deploy)"
  plain_call test1 Accept "$IMPL"
fi

step "fund prov2 with 3000 GNOT"
KEY=test1 tx send -to "$PROV2" -send 3000000000ugnot -gas-fee 1000000ugnot -gas-wanted 2000000

step "lower the stake floor for the demo (rate limit: several steps)"
FLOOR="$(qeval "$CORE.Param(\"providerMinStakeFloor\")" | grep -oE '[0-9]+' | head -1)"
for v in 5000000000 2500000000 1250000000 1000000000; do
  [ "$FLOOR" -gt "$v" ] || continue
  plain_call test1 SetParam providerMinStakeFloor "$v"; FLOOR="$v"
done
echo "floor: $FLOOR"

step "propose a one-minute price feed (deposit 5 + first period 100 GNOT)"
SPEC='{"name":"DEMO/USD","description":"gnodev smoke feed","kind":"recurring","valueType":"numeric","decimals":6,"interval":60,"submitWindow":60,"sources":"Any number; this is a demo.","minProviders":2,"maxProviders":3,"providerMinStake":1000000000,"toleranceBps":100,"quarantineBps":1000,"disputeWindow":7200,"readPrice":20000,"subscriptionPrice":100000000}'
send_call test1 ProposeFeed 105000000ugnot "$SPEC"
FEED="$(qeval "$CORE.FeedCount()" | grep -oE '[0-9]+' | head -1)"
echo "feed id: $FEED"

step "activate"
plain_call test1 ActivateFeed "$FEED"

step "register two providers (1000 GNOT each)"
send_call test1 Register 1000000000ugnot "$FEED" "test1 provider"
send_call prov2 Register 1000000000ugnot "$FEED" "prov2 provider"

step "wait for round 0 to open"
# gnodev makes blocks lazily and a block's time is the previous commit's, so
# chain time lags the wall clock until transactions flow: send cheap ticks
# until the realm's own clock has passed the round's open time.
START="$(qeval "$CORE.GetFeed($FEED).StartAt" | grep -oE '[0-9]+' | head -1)"
tick() { KEY=test1 tx send -to "$TEST1" -send 1ugnot -gas-fee 1000000ugnot -gas-wanted 2000000 >/dev/null 2>&1 || true; }
while :; do
  NOW="$(qeval "$CORE.Now()" | grep -oE '[0-9]+' | head -1)"
  [ "$NOW" -ge "$((START + 1))" ] && break
  sleep 2; tick; sleep 1; tick
done
echo "chain time $NOW >= open $START"

step "submit round 0 from both providers (second submission finalises early)"
plain_call test1 Submit "$FEED" 0 1000000
plain_call prov2 Submit "$FEED" 0 1004000

step "round 1: measure the marginal storage of one more round"
while :; do
  NOW="$(qeval "$CORE.Now()" | grep -oE '[0-9]+' | head -1)"
  [ "$NOW" -ge "$((START + 61))" ] && break
  sleep 2; tick; sleep 1; tick
done
plain_call test1 Submit "$FEED" 1 1001000
plain_call prov2 Submit "$FEED" 1 1002000

step "deposit credit and read"
send_call test1 DepositFor 1000000ugnot "$TEST1"
plain_call test1 Read "$FEED"

step "DAO: accept its implementation, stake PYTH, sync fees, open and vote a proposal"
DAO="gno.land/r/$NS/gnoracle/dao"
TOKEN="gno.land/r/$NS/gnoracle/token"
DAOIMPL="$DAO/impl/v1"
DAOADDR="$(qeval "$DAO.Address()" 2>/dev/null | grep -oE 'g1[0-9a-z]{38}' | head -1)"
if [ "$(qeval "$DAO.LivePath()")" != "(\"$DAOIMPL\" string)" ]; then
  KEY=test1 tx call -pkgpath "$DAO" -func Accept -args "$DAOIMPL" -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
fi
echo "dao live: $(qeval "$DAO.LivePath()")"
echo "test1 PYTH: $(qeval "$TOKEN.BalanceOf(\"$TEST1\")")"
KEY=test1 tx call -pkgpath "$TOKEN" -func Approve -args "$DAOADDR" -args 1000000000000 -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
KEY=test1 tx call -pkgpath "$DAO" -func Stake -args 1000000000000 -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
echo "staked: $(qeval "$DAO.TotalStaked()")"
step "forward the core's pending fees to the DAO and sync them"
KEY=test1 tx call -pkgpath "$CORE" -func SetParamStr -args daoRealm -args "$DAO" -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot || true
KEY=test1 tx call -pkgpath "$CORE" -func ForwardFees -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
KEY=test1 tx call -pkgpath "$DAO" -func SyncFees -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
echo "fees owed to test1: $(qeval "$DAO.FeesOwed(\"$TEST1\")")"
echo "dao health: $(qeval "$DAO.Health()")"
step "a text proposal and a vote (voting weight activates next epoch, so this may need ~1h of chain time)"
KEY=test1 tx call -pkgpath "$DAO" -func Propose -args text -args "hello" -args "First proposal" -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
echo "proposals: $(qeval "$DAO.ProposalCount()")"

step "Kourt mirror: accept its implementation, found the court, fund the float"
KOURT="gno.land/r/$NS/gnoracle/kourt"
KDEV="gno.land/r/$NS/gnoracle/kourtdev"
KIMPL="$KOURT/impl/v1"
if [ "$(qeval "$KOURT.LivePath()")" != "(\"$KIMPL\" string)" ]; then
  KEY=test1 tx call -pkgpath "$KOURT" -func Accept -args "$KIMPL" -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
fi
KEY=test1 tx call -pkgpath "$KOURT" -func EnsureCourt -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
KADDR="$(qeval "$KOURT.Address()" | grep -oE 'g1[0-9a-z]{38}' | head -1)"
KEY=test1 tx call -pkgpath "$KDEV" -func Buy -args gnoracle -args 0 -send 10000000ugnot -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
KEY=test1 tx call -pkgpath "$KDEV" -func TransferCC -args gnoracle -args "$KADDR" -args 10000000 -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
echo "mirror float (CC): $(qeval "$KDEV.CoinBalanceOf(\"gnoracle\", \"$KADDR\")")"

step "health and page"
echo "$(qeval "$CORE.Health()")"
qrender "$CORE" "feed/$FEED" | head -30
echo
echo "chain-test: done"

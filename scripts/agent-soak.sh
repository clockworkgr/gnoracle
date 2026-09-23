#!/usr/bin/env bash
# The plan's gnodev scenario (§12.1): several provider agents and the bot
# against a running local chain for a few minutes, then assertions on the
# rounds, the providers and the realms' conservation checks.
#
# Needs a local chain with an active feed and the dev keybase:
#   make dev RPC=36657 WEB=38888        # in another shell
#   make dev-keys && REMOTE=http://127.0.0.1:36657 make chain-test   # creates and activates feed 1
#   REMOTE=http://127.0.0.1:36657 make agent-soak
#
# Variables: FEED (1), AGENTS (3: test1 plus new keys), EXTRA_KEYS (existing
# dev keys to run as agents too, e.g. "prov2"), DURATION (240 s), PRICE_PORT
# (38999), REMOTE, CHAINID (dev), GNOKEY_PASSWORD (devpassword).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
export GNOKEY_HOME="$here/.dev-keys"
export GNOKEY_PASSWORD="${GNOKEY_PASSWORD:-devpassword}"
export GNORACLE_KEY_PASSWORD="$GNOKEY_PASSWORD"
GNOKEY="${GNOKEY:-$HOME/.cache/gno-toolchains/${GNO_REF:-v1.2.0}/gnokey}"
export GNOKEY
# shellcheck source=env.sh
. "$here/scripts/env.sh"

FEED="${FEED:-1}"
AGENTS="${AGENTS:-3}"
DURATION="${DURATION:-240}"
PRICE_PORT="${PRICE_PORT:-38999}"
OUT="$here/.dev-agent/soak"
CLI=(bin/gnoracle -remote "$REMOTE" -chain "$CHAINID" -ns clockwork)
CORE="gno.land/r/clockwork/gnoracle/core"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
jq_() { python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }

rm -rf "$OUT"; mkdir -p "$OUT/www"
make -s go-build

step "feed $FEED"
"${CLI[@]}" -raw feed "$FEED" > "$OUT/feed.json" || fail "feed $FEED is not readable; run make chain-test first"
read -r STATUS INTERVAL WINDOW MAXP ACTIVE MINSTAKE < <(jq_ 'print(d["status"], d["spec"]["interval"], d["spec"]["submitWindow"], d["spec"]["maxProviders"], d["activeCount"], d["spec"]["providerMinStake"])' < "$OUT/feed.json")
echo "status $STATUS, interval ${INTERVAL}s, window ${WINDOW}s, providers $ACTIVE/$MAXP, min stake $MINSTAKE ugnot"
[ "$STATUS" = active ] || fail "feed $FEED is $STATUS"
[ "$DURATION" -ge $((3 * INTERVAL)) ] || echo "note: DURATION $DURATION covers fewer than three rounds of ${INTERVAL}s"

step "keys and registrations"
KEYS=(test1)
for name in ${EXTRA_KEYS:-}; do
  addr="$(gk list 2>/dev/null | grep -A1 " $name " | grep -oE 'g1[0-9a-z]{38}' | head -1)"
  [ -n "$addr" ] || fail "EXTRA_KEYS: no key named $name in $GNOKEY_HOME"
  echo "$name ($addr): existing key, runs as an agent"
  KEYS+=("$name")
done
for n in $(seq 1 $((AGENTS - 1 - $(echo ${EXTRA_KEYS:-} | wc -w)))); do
  name="soak$n"
  if ! gk list 2>/dev/null | grep -q " $name "; then
    printf '%s\n%s\n' "$GNOKEY_PASSWORD" "$GNOKEY_PASSWORD" | gk add -insecure-password-stdin "$name" >/dev/null
  fi
  addr="$(gk list 2>/dev/null | grep -A1 " $name " | grep -oE 'g1[0-9a-z]{38}' | head -1)"
  if "${CLI[@]}" -raw providers "$FEED" | jq_ "import sys; sys.exit(0 if any(p['addr']=='$addr' and p['status']=='active' for p in d['providers']) else 1)"; then
    echo "$name ($addr): already an active provider"
    KEYS+=("$name"); continue
  fi
  need=$((MINSTAKE + 600000000))
  KEY=test1 tx send -to "$addr" -send "${need}ugnot" -gas-fee 2000ugnot -gas-wanted 2000000 >/dev/null 2>&1 || true
  if out="$(GNORACLE_KEY_HOME="$GNOKEY_HOME" GNORACLE_KEY="$name" "${CLI[@]}" register "$FEED" "${MINSTAKE}ugnot" "soak agent $name" 2>&1)"; then
    echo "$name ($addr): registered"
    KEYS+=("$name")
  else
    echo "$name ($addr): not registered: ${out##*error: }"
  fi
done
echo "agents: ${KEYS[*]}"
[ "${#KEYS[@]}" -ge 2 ] || fail "need at least two agents; free a provider slot on feed $FEED"

step "configs"
echo '{"data":{"base":"GNOT","currency":"USD","amount":"1.0012"}}' > "$OUT/www/price.json"
i=0
for name in "${KEYS[@]}"; do
  i=$((i + 1))
  if [ $((i % 2)) -eq 1 ]; then
    src=$'adapter = "http"\nurls = ["http://127.0.0.1:'"$PRICE_PORT"$'/price.json"]\npath = "data.amount"'
  else
    src=$'adapter = "exec"\ncommand = ["sh", "-c", "printf \'1.00%02d\\n\' $((RANDOM % 40))"]'
  fi
  cat > "$OUT/$name.toml" <<CFG
remote = "$REMOTE"
chain_id = "$CHAINID"
core = "$CORE"
key_home = "$GNOKEY_HOME"
key = "$name"
state = "$OUT/$name-state.json"
journal = "$OUT/$name-journal.jsonl"
poll = "2s"
dev_tick = true
[[feeds]]
id = $FEED
jitter = "${i}s"
finalize_delay = "$((3 * i))s"
[feeds.source]
$src
CFG
done
sed -e "s#^remote.*#remote = \"$REMOTE\"#" -e "s#^chain_id.*#chain_id = \"$CHAINID\"#" -e "s#^key_home.*#key_home = \"$GNOKEY_HOME\"#" -e "s#^state.*#state = \"$OUT/bot-state.json\"#" configs/bot.dev.toml > "$OUT/bot.toml"

step "running ${#KEYS[@]} agents and the bot for ${DURATION}s"
if lsof -nP -iTCP:"$PRICE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "port $PRICE_PORT is in use; set PRICE_PORT to a free one"
fi
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null || true' EXIT   # armed before anything starts
(cd "$OUT/www" && exec python3 -m http.server "$PRICE_PORT" --bind 127.0.0.1 >"$OUT/www.log" 2>&1) &
PIDS+=($!)
sleep 1
for name in "${KEYS[@]}"; do
  bin/gnoracle-agent -config "$OUT/$name.toml" > "$OUT/$name.log" 2>&1 &
  PIDS+=($!)
done
bin/gnoracle-bot -config "$OUT/bot.toml" > "$OUT/bot.log" 2>&1 &
PIDS+=($!)
sleep "$DURATION"
kill "${PIDS[@]}" 2>/dev/null || true
trap - EXIT
sleep 1

step "results"
for name in "${KEYS[@]}"; do
  printf '%-6s submitted %s round(s), finalised %s, errors %s\n' "$name" "$(grep -c '"kind":"submit"' "$OUT/$name-journal.jsonl" 2>/dev/null || true)" "$(grep -c '"kind":"finalize"' "$OUT/$name-journal.jsonl" 2>/dev/null || true)" "$(grep -c '"kind":"error"' "$OUT/$name-journal.jsonl" 2>/dev/null || true)"
done
"${CLI[@]}" -raw rounds "$FEED" 6 > "$OUT/rounds.json"
jq_ '[print(" round", r["id"], r["status"], r["tier"], "submitters", len(r["submitted"]), "pool", r["pool"]) for r in d["rounds"]]' < "$OUT/rounds.json"
"${CLI[@]}" -raw providers "$FEED" > "$OUT/providers.json"
jq_ '[print(" provider", p["addr"][:12], p["status"], "rewards", p["rewards"], "misses", p["consecutiveMisses"]) for p in d["providers"]]' < "$OUT/providers.json"

step "assertions"
ok=1
# the last three rounds finalised with at least two submitters, none void
if ! jq_ 'import sys; rs=[r for r in d["rounds"] if r["status"]!="open"][:3]; sys.exit(0 if len(rs)==3 and all(r["status"]=="aggregated" and len(r["submitted"])>=2 for r in rs) else 1)' < "$OUT/rounds.json"; then
  echo "x the last three finalised rounds are not all aggregated with two or more submitters"; ok=0
else echo "- three consecutive aggregated rounds with two or more submitters"; fi
if ! jq_ 'import sys; sys.exit(0 if any(r["tier"]=="consensus" for r in d["rounds"]) else 1)' < "$OUT/rounds.json"; then
  echo "x no round reached consensus"; ok=0
else echo "- consensus reached"; fi
# every running agent earned something
for name in "${KEYS[@]}"; do
  addr="$(gk list 2>/dev/null | grep -A1 " $name " | grep -oE 'g1[0-9a-z]{38}' | head -1)"
  if ! jq_ "import sys; sys.exit(0 if any(p['addr']=='$addr' and p['totalEarned']>0 for p in d['providers']) else 1)" < "$OUT/providers.json"; then
    echo "x $name earned nothing"; ok=0
  else echo "- $name earned rewards"; fi
done
# conservation
"${CLI[@]}" -raw health > "$OUT/health.json" 2>/dev/null || true
if ! head -1 "$OUT/health.json" | jq_ 'import sys, json; sys.exit(0 if json.loads(d["health"])["status"]=="ok" else 1)'; then
  echo "x core health is not ok"; ok=0
else echo "- core health ok"; fi
if ! sed -n 2p "$OUT/health.json" | jq_ 'import sys, json; sys.exit(0 if json.loads(d["health"])["status"]=="ok" else 1)'; then
  echo "x dao health is not ok"; ok=0
else echo "- dao health ok"; fi
# the bot announced finalisations
if ! grep -q "RoundFinalized" "$OUT/bot.log"; then echo "x the bot announced no finalisation"; ok=0; else echo "- bot announced finalisations"; fi

[ "$ok" = 1 ] && echo "soak: PASS (logs in $OUT)" || fail "soak failed (logs in $OUT)"

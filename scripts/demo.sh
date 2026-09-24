#!/usr/bin/env bash
# The whole Gnoracle story on a local chain in a few minutes (docs/DEMO.md):
# a price feed with three provider agents and the notifier bot, an example
# consumer realm that reads the feed and keeps every value with its block
# height, a dispute against a round, the DAO's commit-reveal ballot, and the
# verdict filed, staked, answered and settled as a claim in the DAO's court
# on Kourt v3. Everything stays up afterwards (the chain with its gnoweb,
# the agents, the bot, the reader's poller) so each page can be inspected;
# the links are printed as each page comes to life and again at the end.
#
#   make demo                  # uses the gnodev on RPC/WEB if one runs, else starts one
#   RESET=1 make demo          # reset a running dev chain first (gnodev's /reset)
#   make demo-stop             # stop what the demo left running
#
# Clocks: a development chain cannot skip time, so the demo shortens the
# ballot and appeal windows through the dev-only floors of the permanent
# realms (chain id "dev"; production defaults are printed beside each) and
# drives Kourt with its own test clock. Variables: DURATION (180 s of live
# rounds), READ_EVERY (20 s between the reader's polls), PRICE_PORT (38998),
# RPC (36657), WEB (38888).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

RPC="${RPC:-36657}"
WEB="${WEB:-38888}"
export NS=clockwork
export REMOTE="${REMOTE:-http://127.0.0.1:$RPC}"
export CHAINID="${CHAINID:-dev}"
export GNOKEY="${GNOKEY:-$HOME/.cache/gno-toolchains/${GNO_REF:-v1.2.0}/gnokey}"
export GNOKEY_HOME="$here/.dev-keys"
export GNOKEY_PASSWORD="${GNOKEY_PASSWORD:-devpassword}"
export GNORACLE_KEY_PASSWORD="$GNOKEY_PASSWORD"
export KEY=test1
# shellcheck source=env.sh
. "$here/scripts/env.sh"

WEBURL="${WEBURL:-http://127.0.0.1:$WEB}"
DURATION="${DURATION:-180}"
READ_EVERY="${READ_EVERY:-20}"
PRICE_PORT="${PRICE_PORT:-38998}"
OUT="$here/.dev-agent/demo"
CORE="gno.land/r/clockwork/gnoracle/core"
DAO="gno.land/r/clockwork/gnoracle/dao"
TOKEN="gno.land/r/clockwork/gnoracle/token"
KOURT="gno.land/r/clockwork/gnoracle/kourt"
KIMPL="$KOURT/impl/kourtv3"
READER="gno.land/r/clockwork/gnoracle/demo/reader"
KV3="gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3"
TEST1=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5
PROVIDERS=(demo1 demo2 demo3)
VOTERS=(test1 voter1 voter2)
CHALLENGER=challenger
BOTKEY=demobot
READERKEY=reader1
CLI=(bin/gnoracle -remote "$REMOTE" -chain "$CHAINID" -ns clockwork -key-home "$GNOKEY_HOME")

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
say() { printf '   %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
jq_() { python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }
qeval() { gk query vm/qeval -data "$1" -remote "$REMOTE" 2>/dev/null | sed '1d; s/^data: //'; }
num() { grep -oE -- '-?[0-9]+' | head -1; }
addr_of() { gk list 2>/dev/null | grep -A1 " $1 " | grep -oE 'g1[0-9a-z]{38}' | head -1; }
# txq: a transaction from $KEY, quiet on success, the node's message on failure
txq() {
  local out try
  for try in 1 2 3 4 5; do
    if out="$(tx "$@" 2>&1)"; then return 0; fi
    # gnokey opens the keybase exclusively; another process (the agents, the
    # poller) may hold it for a moment
    grep -q "resource temporarily unavailable\|error initializing DB" <<<"$out" || break
    sleep 1
  done
  # the node's message, without the stack frames around it
  printf '%s\n' "$out" | grep -v '^\s*$' | grep -v '^\s*[0-9]\+ \|elided\|^--=\|gas used\|suggested gas\|^height\|^events\|^tx hash\|^ok!' | sed 's/^.*VM call panic: //; s/^.*log:msg:0,success:false,log://' | head -6 >&2
  return 1
}
callq() {
  local pkg="$1" fn="$2"; shift 2
  local args=()
  for a in "$@"; do args+=(-args "$a"); done
  txq call -pkgpath "$pkg" -func "$fn" "${args[@]}" -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
}
sendcallq() {
  local pkg="$1" fn="$2" send="$3"; shift 3
  local args=()
  for a in "$@"; do args+=(-args "$a"); done
  txq call -pkgpath "$pkg" -func "$fn" "${args[@]}" -send "$send" -gas-fee "$CALL_GAS_FEE" -gas-wanted "$CALL_GAS_WANTED" -max-deposit 50000000ugnot
}
tick() { KEY=test1 txq send -to "$TEST1" -send 1ugnot -gas-fee 2000ugnot -gas-wanted 2000000 || true; }
fund() { KEY=test1 txq send -to "$1" -send "$2" -gas-fee 2000ugnot -gas-wanted 2000000; }
ensure_key() {
  local keys
  keys="$(gk list 2>/dev/null || true)"
  grep -q " $1 " <<<"$keys" || printf '%s\n%s\n' "$GNOKEY_PASSWORD" "$GNOKEY_PASSWORD" | gk add -insecure-password-stdin "$1" >/dev/null 2>&1
}
# wait_for <what> <timeout s> <command...>: poll the command, ticking the
# chain's clock meanwhile (gnodev only makes blocks when transactions flow)
wait_for() {
  local what="$1" timeout="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  while ! "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "timed out after ${timeout}s waiting for $what"
    tick; sleep 3
  done
}
# lower_param <core|dao> <name> <target>: halve down to the target (each
# parameter changes by at most 50% per block)
lower_param() {
  local realm="$1" name="$2" target="$3" pkg fn cur next
  if [ "$realm" = core ]; then pkg="$CORE"; fn=SetParam; else pkg="$DAO"; fn=DevSetParam; fi
  cur="$(qeval "$pkg.Param(\"$name\")" | num)"
  local from="$cur"
  while [ "$cur" -gt "$target" ]; do
    next=$((cur - cur / 2)); [ "$next" -ge "$target" ] || next="$target"   # a step down of at most half, rounded in the limit's favour
    [ "$next" -lt "$cur" ] || next="$target"                                   # a bound itself is always reachable
    KEY=test1 callq "$pkg" "$fn" "$name" "$next" || fail "could not set $realm.$name to $next"
    cur="$(qeval "$pkg.Param(\"$name\")" | num)"
  done
  printf '   %-28s %-12s (was %s)\n' "$realm.$name" "$cur" "$from"
}
pids_add() { echo "$1 $2" >> "$OUT/pids"; }
# detach <label> <log> <command...>: run in the background, surviving this
# script and its terminal (macOS has no setsid; nohup plus disown does it)
detach() {
  local label="$1" log="$2"; shift 2
  nohup "$@" > "$log" 2>&1 < /dev/null &
  disown "$!" 2>/dev/null || true
  pids_add "$label" "$!"
}
link() { printf '   %-22s %s\n' "$1" "$2"; }

# ---------------------------------------------------------------- modes ----

poll_loop() { # poll <feed> <every>: the reader realm reads the feed on a schedule
  local feed="$1" every="$2" n=0
  while :; do
    if KEY="$READERKEY" callq "$READER" Poll "$feed"; then
      n=$((n + 1))
      echo "$(date +%T) poll #$n ok"
    else
      echo "$(date +%T) poll failed (see above)"
    fi
    sleep "$every"
  done
}

stop_all() {
  [ -f "$OUT/pids" ] || { echo "demo: nothing recorded in $OUT/pids"; return 0; }
  local kept=()
  while read -r label pid; do
    case "$label" in gnodev*) if [ "${KEEP_CHAIN:-0}" = 1 ]; then echo "keeping the chain ($label $pid)"; kept+=("$label $pid"); continue; fi ;; esac
    if kill "$pid" 2>/dev/null; then echo "stopped $label ($pid)"; fi
  done < "$OUT/pids"
  rm -f "$OUT/pids"
  local k
  for k in "${kept[@]+"${kept[@]}"}"; do echo "$k" >> "$OUT/pids"; done
}

# ----------------------------------------------------------------- main ----

preflight() {
  step "preflight"
  [ -x "$GNOKEY" ] || fail "gnokey not found at $GNOKEY (run make toolchain)"
  command -v python3 >/dev/null || fail "python3 is needed"
  mkdir -p "$OUT/www"
  if [ -f "$OUT/pids" ]; then say "stopping the previous demo's processes"; KEEP_CHAIN=1 stop_all >/dev/null || true; fi
  make -s go-build
  "$here/scripts/dev-keys.sh" >/dev/null
  say "keys in $GNOKEY_HOME, logs in $OUT"
}

ensure_chain() {
  if ! lsof -nP -iTCP:"$RPC" -sTCP:LISTEN >/dev/null 2>&1; then
    step "starting a local chain (make dev RPC=$RPC WEB=$WEB); it stays up after the demo"
    detach gnodev-make "$OUT/gnodev.log" make -s dev RPC="$RPC" WEB="$WEB" WATCH=0
    STARTED_CHAIN=1
  elif [ "${RESET:-0}" = 1 ]; then
    step "resetting the running chain (POST $WEBURL/reset)"
    curl -fsS -m 60 -X POST "$WEBURL/reset" -o /dev/null || fail "reset failed: is gnodev's unsafe API on (the default) and WEB=$WEB its web port?"
  else
    step "using the chain on $REMOTE (RESET=1 to start from a clean one)"
    say "note: a chain started with WATCH=1 hot-reloads on any edit in the repository and comes back half-applied; the demo starts its own with -no-watch"
  fi
  local deadline=$((SECONDS + 240))
  until pkg_exists "$CORE" && pkg_exists "$READER" && pkg_exists "$KV3"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "the chain on $REMOTE does not serve $CORE, $READER and $KV3; restart make dev (its package set changed)"
    sleep 2
  done
  if [ "${STARTED_CHAIN:-0}" = 1 ]; then
    local pid
    pid="$(lsof -nP -iTCP:"$RPC" -sTCP:LISTEN -t 2>/dev/null | head -1)"
    [ -n "$pid" ] && pids_add gnodev-node "$pid"
  fi
  deadline=$((SECONDS + 90))
  until curl -fsS -m 5 -o /dev/null "$WEBURL/"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "gnoweb does not answer on $WEBURL (gnodev serves it on its web listener; WEB=$WEB)"
    sleep 2
  done
  say "chain height $(curl -s -m 5 "$REMOTE/status" | jq_ 'print(d["result"]["sync_info"]["latest_block_height"])') on $REMOTE"
  say "gnoweb is up: $WEBURL (open it now; the pages below appear as the demo reaches them)"
  link "core realm" "$WEBURL/r/clockwork/gnoracle/core"
  link "DAO realm" "$WEBURL/r/clockwork/gnoracle/dao"
  link "Kourt mirror" "$WEBURL/r/clockwork/gnoracle/kourt"
  link "Kourt v3 (the court)" "$WEBURL/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3"
  link "reader realm" "$WEBURL/r/clockwork/gnoracle/demo/reader"
}

accept_releases() {
  step "releases"
  local pkg impl
  for pair in "$CORE=$CORE/impl/v1" "$DAO=$DAO/impl/v1" "$KOURT=$KIMPL"; do
    pkg="${pair%%=*}"; impl="${pair#*=}"
    if [ "$(qeval "$pkg.LivePath()")" != "(\"$impl\" string)" ]; then
      KEY=test1 callq "$pkg" Accept "$impl" || fail "could not accept $impl"
    fi
    say "${pkg##*/}: $(qeval "$pkg.LivePath()" | tr -d '()' | sed 's/ string//')"
  done
}

arm_kourt_clock() {
  step "Kourt's test clock (the mirror reads Kourt's own clock, so the claim's waits can be skipped)"
  KOURT_FAST=1
  if [ "$(qeval "$KV3.TestClockActive()")" = "(true bool)" ]; then say "already armed"; return; fi
  local courts
  courts="$(qeval "$KV3.CourtCount()" | num)"
  if [ "${courts:-0}" -le 1 ] && KEY=test1 callq "$KV3" EnableTestClock; then
    say "armed by test1 (the realm's deployer on this chain)"
  else
    KOURT_FAST=0
    say "not available: a court already exists on this chain or test1 did not deploy the realm."
    say "The claim will run on Kourt's real clock (answer after ~3 h of blocks, settle 72 h later); RESET=1 for a clean chain."
  fi
}

dev_clocks() {
  step "demo clocks on this development chain (production defaults in parentheses; floors exist only on chain id dev)"
  lower_param dao commitPeriod 60        # 24 h
  lower_param dao revealPeriod 60        # 24 h
  lower_param core appealWindow 30       # 24 h
  lower_param dao epochBlocks 10         # 720 blocks: voting weight activates at the next epoch
  lower_param core providerMinStakeFloor 1000000000   # 10,000 GNOT
}

keys_and_funding() {
  step "keys: three provider agents, two members, a challenger, the bot, the reader's poller"
  local k
  for k in "${PROVIDERS[@]}" voter1 voter2 "$CHALLENGER" "$BOTKEY" "$READERKEY"; do ensure_key "$k"; done
  for k in "${PROVIDERS[@]}"; do fund "$(addr_of "$k")" 1700000000ugnot; done      # 1000 GNOT stake plus fees
  for k in voter1 voter2 "$BOTKEY" "$READERKEY"; do fund "$(addr_of "$k")" 100000000ugnot; done
  fund "$(addr_of "$CHALLENGER")" 2600000000ugnot                                    # the 2,500 GNOT dispute bond plus fees
  for k in "${PROVIDERS[@]}" voter1 voter2 "$CHALLENGER" "$BOTKEY" "$READERKEY"; do say "$k $(addr_of "$k")"; done
}

members() {
  step "DAO members: test1, voter1 and voter2 stake PYTH (their weight counts from the next epoch)"
  local v addr staked
  local epoch0
  epoch0="$(qeval "$DAO.Epoch()" | num)"
  for v in "${VOTERS[@]}"; do
    addr="$(addr_of "$v")"
    staked="$("${CLI[@]}" -raw member "$addr" 2>/dev/null | jq_ 'print(d.get("staked", 0))' || echo 0)"
    if [ "${staked:-0}" -gt 0 ]; then say "$v already staked $staked"; continue; fi
    if [ "$v" != test1 ]; then KEY=test1 callq "$TOKEN" Transfer "$addr" 100000000000 || fail "PYTH transfer to $v"; fi
    "${CLI[@]}" -key "$v" stake 100000 >/dev/null || fail "$v could not stake"   # 100,000 PYTH
    say "$v staked 100,000 PYTH"
  done
  epoch_reached() { [ "$(qeval "$DAO.Epoch()" | num)" -ge "$((epoch0 + 1))" ]; }
  wait_for "the next voting epoch" 120 epoch_reached
  say "epoch $(qeval "$DAO.Epoch()" | num), total staked $(qeval "$DAO.TotalStaked()" | num)"
}

create_feed() {
  step "feed: propose and activate DEMO/USD (one-minute rounds), register three providers, subscribe the reader realm"
  local spec p
  spec='{"name":"DEMO/USD","description":"the demo feed: three agents, one reader realm","kind":"recurring","valueType":"numeric","decimals":6,"interval":60,"submitWindow":60,"sources":"Any number; this is a demo.","minProviders":2,"maxProviders":3,"providerMinStake":1000000000,"toleranceBps":100,"quarantineBps":1000,"disputeWindow":7200,"subscriberPrice":10000000,"subscriptionPrice":100000000}'
  KEY=test1 sendcallq "$CORE" ProposeFeed 105000000ugnot "$spec" || fail "ProposeFeed"
  FEED="$(qeval "$CORE.FeedCount()" | num)"
  KEY=test1 callq "$CORE" ActivateFeed "$FEED" || fail "ActivateFeed"
  for p in "${PROVIDERS[@]}"; do
    KEY="$p" sendcallq "$CORE" Register 1000000000ugnot "$FEED" "demo agent $p" || fail "$p could not register"
  done
  READER_ADDR="$(qeval "$READER.Address()" | grep -oE 'g1[0-9a-z]{38}' | head -1)"
  # a read costs nothing per call; the core serves it to subscribed realms, 10 GNOT per 30-day period on this feed
  KEY=test1 sendcallq "$CORE" SubscribeRealm 10000000ugnot "$FEED" "$READER" 1 || fail "SubscribeRealm for the reader"
  START="$(qeval "$CORE.GetFeed($FEED).StartAt" | num)"
  say "feed $FEED active, first round at chain time $START; reader realm $READER subscribed for one period (10 GNOT)"
  link "feed page" "$WEBURL/r/clockwork/gnoracle/core:feed/$FEED"
  link "its rounds" "$WEBURL/r/clockwork/gnoracle/core:feed/$FEED/rounds"
  link "reader realm" "$WEBURL/r/clockwork/gnoracle/demo/reader"
  link "feed subscribers" "$WEBURL/r/clockwork/gnoracle/core:feed/$FEED/subscribers"
}

write_configs() {
  echo '{"data":{"base":"GNOT","currency":"USD","amount":"1.0012"}}' > "$OUT/www/price.json"
  local i=0 name src
  for name in "${PROVIDERS[@]}"; do
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
  sed -e "s#^remote.*#remote = \"$REMOTE\"#" -e "s#^chain_id.*#chain_id = \"$CHAINID\"#" -e "s#^key_home.*#key_home = \"$GNOKEY_HOME\"#" \
      -e "s#^key .*#key      = \"$BOTKEY\"#" -e "s#^state.*#state = \"$OUT/bot-state.json\"#" -e "s#^gnoweb.*#gnoweb   = \"$WEBURL\"#" \
      configs/bot.dev.toml > "$OUT/bot.toml"
}

start_workers() {
  step "starting three agents, the bot and the reader's poller (they keep running after the demo)"
  if lsof -nP -iTCP:"$PRICE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then fail "port $PRICE_PORT is in use; set PRICE_PORT"; fi
  detach price-server "$OUT/www.log" python3 -m http.server "$PRICE_PORT" --bind 127.0.0.1 --directory "$OUT/www"
  sleep 1
  local name
  for name in "${PROVIDERS[@]}"; do
    detach "agent-$name" "$OUT/$name.log" bin/gnoracle-agent -config "$OUT/$name.toml"
  done
  detach bot "$OUT/bot.log" bin/gnoracle-bot -config "$OUT/bot.toml"
  detach reader-poller "$OUT/reader-poll.log" bash "$0" poll "$FEED" "$READ_EVERY"
  say "agents ${PROVIDERS[*]} (http and exec adapters), bot $BOTKEY, reader polls every ${READ_EVERY}s as $READERKEY"
  say "watch the rounds arrive on the feed page and the readings on the reader realm's page (links above)"
}

live_phase() {
  local now wait_s elapsed=0 last=0 count
  now="$(qeval "$CORE.Now()" | num)"
  wait_s=$(( (START > now ? START - now : 0) + DURATION ))
  step "live: ${wait_s}s of rounds (first round in $((START > now ? START - now : 0))s, then ${DURATION}s)"
  while [ "$elapsed" -lt "$wait_s" ]; do
    sleep 30; elapsed=$((elapsed + 30))
    last="$("${CLI[@]}" -raw feed "$FEED" 2>/dev/null | jq_ 'print(d.get("lastRound", 0) if d.get("haveValue") else -1)' || echo -1)"
    count="$(qrender "$READER" json 2>/dev/null | jq_ 'print(d["count"])' || echo 0)"
    say "$(date +%T): latest round with a value $last, reader readings $count"
  done
}

results() {
  step "results"
  local name
  for name in "${PROVIDERS[@]}"; do
    printf '   %-6s submitted %s round(s), finalised %s, errors %s\n' "$name" "$(grep -c '"kind":"submit"' "$OUT/$name-journal.jsonl" 2>/dev/null || true)" "$(grep -c '"kind":"finalize"' "$OUT/$name-journal.jsonl" 2>/dev/null || true)" "$(grep -c '"kind":"error"' "$OUT/$name-journal.jsonl" 2>/dev/null || true)"
  done
  "${CLI[@]}" -raw rounds "$FEED" 6 > "$OUT/rounds.json"
  jq_ '[print("   round", r["id"], r["status"], r["tier"], "submitters", len(r["submitted"]), "pool", r["pool"]) for r in d["rounds"]]' < "$OUT/rounds.json"
  qrender "$READER" json > "$OUT/readings.json"
  jq_ 'print("   reader:", d["count"], "readings, subscribed until chain time", d["subscribedUntil"]); [print("    #%s height %s round %s value %s (%s)" % (r["seq"], r["height"], r["round"], r["value"], r["tier"])) for r in d["readings"][:5]]' < "$OUT/readings.json"
  local ok=1
  if ! jq_ 'import sys; rs=[r for r in d["rounds"] if r["status"]!="open"][:3]; sys.exit(0 if len(rs)==3 and all(r["status"]=="aggregated" and len(r["submitted"])>=2 for r in rs) else 1)' < "$OUT/rounds.json"; then
    echo "   x the last three finalised rounds are not all aggregated with two or more submitters"; ok=0
  else say "- three consecutive aggregated rounds with two or more submitters"; fi
  if ! jq_ 'import sys; sys.exit(0 if d["count"]>=3 and all(r["height"]>0 for r in d["readings"]) and any(r["value"]>0 for r in d["readings"]) else 1)' < "$OUT/readings.json"; then
    echo "   x the reader realm did not record three readings with heights and a value"; ok=0
  else say "- the reader realm recorded the feed with block heights"; fi
  [ "$ok" = 1 ] || fail "the live phase did not produce the expected rounds (logs in $OUT)"
}

open_dispute() {
  step "dispute: the challenger contests the round the reader realm last read (proposes a value 5% higher, minor tier, 2,500 GNOT bond)"
  read -r ROUND VALUE < <(jq_ 'rs=[r for r in d["readings"] if r["value"]>0]; print(rs[0]["round"], rs[0]["value"])' < "$OUT/readings.json")
  say "the reader realm's latest reading: round $ROUND, value $VALUE (as served, six decimals)"
  local proposed
  proposed="$(python3 -c "print('%.6f' % ($VALUE * 1.05 / 1e6))")"
  "${CLI[@]}" -key "$CHALLENGER" dispute-open "$FEED" "$ROUND" "$proposed" minor "demo: the challenger claims round $ROUND settled 5% too low" 2500gnot > "$OUT/dispute-open.log" 2>&1 || { cat "$OUT/dispute-open.log"; fail "dispute-open"; }
  DID="$(qeval "$CORE.DisputeCount()" | num)"
  "${CLI[@]}" -raw dispute "$DID" > "$OUT/dispute.json"
  jq_ 'print("   dispute", d["id"], "on feed", d["feed"], "round", d["round"], "status", d["status"], "bond", d["bond"], "ugnot; proposed", d["proposedValue"], "vs", d["priorValue"])' < "$OUT/dispute.json"
  "${CLI[@]}" -raw ballot "$DID" > "$OUT/ballot.json"
  jq_ 'print("   ballot", d["seq"], "phase", d["phase"], "obligated weight", d["obligated"], "commit ends in", d["commitEnds"]-d["now"], "s, reveal ends in", d["revealEnds"]-d["now"], "s")' < "$OUT/ballot.json"
  link "dispute page" "$WEBURL/r/clockwork/gnoracle/core:dispute/$DID"
  link "all disputes" "$WEBURL/r/clockwork/gnoracle/core:disputes"
  link "DAO members" "$WEBURL/r/clockwork/gnoracle/dao:members"
}

ballot_phase() { "${CLI[@]}" -raw ballot "$DID" 2>/dev/null | jq_ 'print("resolved" if d.get("resolvedAt",0)>0 or d["phase"]=="resolved" else "commit" if d["now"]<d["commitEnds"] else "reveal" if d["now"]<d["revealEnds"] else "finished")'; }
phase_is() { [ "$(ballot_phase)" = "$1" ]; }
dispute_status() { "${CLI[@]}" -raw dispute "$DID" 2>/dev/null | jq_ 'print(d["status"])'; }
status_is() { [ "$(dispute_status)" = "$1" ]; }
appeal_window_over() { "${CLI[@]}" -raw dispute "$DID" 2>/dev/null | jq_ 'import sys; sys.exit(0 if d["status"]!="decided" or d["now"]>=d["appealWindowEnds"] else 1)'; }

vote() {
  step "ballot: the three members commit UPHOLD, reveal when the phase turns, and the dispute resolves"
  local v
  for v in "${VOTERS[@]}"; do
    GNORACLE_HOME="$OUT/home-$v" "${CLI[@]}" -key "$v" commit "$DID" UPHOLD > "$OUT/commit-$v.log" 2>&1 || { cat "$OUT/commit-$v.log"; fail "$v could not commit"; }
    say "$v committed (salt kept in $OUT/home-$v/votes)"
  done
  wait_for "the reveal phase" 240 phase_is reveal
  for v in "${VOTERS[@]}"; do
    GNORACLE_HOME="$OUT/home-$v" "${CLI[@]}" -key "$v" reveal "$DID" > "$OUT/reveal-$v.log" 2>&1 || { cat "$OUT/reveal-$v.log"; fail "$v could not reveal"; }
    say "$v revealed UPHOLD"
  done
  reveal_done() { phase_is finished || phase_is resolved; }
  wait_for "the reveal phase to end" 240 reveal_done
  if status_is open; then "${CLI[@]}" -key test1 resolve "$DID" >/dev/null 2>&1 || true; fi   # the bot may have been first
  wait_for "the ballot to be counted" 60 status_is decided
  "${CLI[@]}" -raw ballot "$DID" > "$OUT/ballot.json"
  jq_ 'print("   counted: outcome", d["outcome"], "uphold", d["uphold"], "overturn", d["overturn"], "revealed", d["revealed"], "of", d["obligated"])' < "$OUT/ballot.json"
  wait_for "the appeal window" 120 appeal_window_over
  if status_is decided; then "${CLI[@]}" -key test1 resolve "$DID" >/dev/null 2>&1 || true; fi
  wait_for "the dispute to resolve" 60 status_is resolved
  "${CLI[@]}" -raw dispute "$DID" > "$OUT/dispute.json"
  jq_ 'print("   resolved:", d["outcome"] + (" at tier " + d["tierDecided"] if d["tierDecided"] else "") + "; the challenger forfeits the bond (split between the prevailing side, the coherent voters and the fees); providers slashed", d["slashed"], "ugnot")' < "$OUT/dispute.json"
}

kourt_state() { "${CLI[@]}" -raw kourt "$DID" 2>/dev/null | jq_ 'print(d["state"] if d.get("exists") else "none")'; }
crank_to() { # <state> <tries>
  local target="$1" tries="${2:-8}" st
  while :; do
    st="$(kourt_state)"
    [ "$st" = "$target" ] && { say "mirror record: $st"; return 0; }
    [ "$tries" -gt 0 ] || fail "the mirror record is $st, not $target"
    tries=$((tries - 1))
    KEY=test1 callq "$KOURT" Crank "$DID" || true
    sleep 1
  done
}

mirror_to_kourt() {
  step "Kourt: found the DAO's court, fund the float, file the verdict as a claim and see it through"
  KEY=test1 callq "$KOURT" EnsureCourt || fail "EnsureCourt"
  say "court $(qeval "$KV3.CourtName(\"gnoracle\")" | tr -d '()' | sed 's/ string//') exists on $KV3 (slug gnoracle)"
  KADDR="$(qeval "$KOURT.Address()" | grep -oE 'g1[0-9a-z]{38}' | head -1)"
  if [ "$(qeval "$KV3.CoinBalanceOf(\"gnoracle\", \"$KADDR\")" | num)" -lt 4000000 ]; then
    KEY=test1 sendcallq "$KV3" Buy 10000000ugnot gnoracle 0 || fail "Buy"
    KEY=test1 callq "$KV3" TransferCC gnoracle "$KADDR" 20000000 || fail "TransferCC"
    say "test1 bought court coin for 10 GNOT and moved 20 CC into the mirror's float"
  fi
  link "the court on Kourt" "$WEBURL/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3:gnoracle"
  crank_to filed
  CLAIM="$("${CLI[@]}" -raw kourt "$DID" | jq_ 'print(d["claim"])')"
  say "claim $CLAIM: $(qeval "$KV3.ClaimTitle(\"gnoracle\", $CLAIM)" | tr -d '()"' | sed 's/ string$//; s/\\\\//g')"
  link "the claim" "$WEBURL/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3:gnoracle/$CLAIM"
  link "mirror record" "$WEBURL/r/clockwork/gnoracle/kourt:dispute/$DID"
  crank_to staked
  if [ "$KOURT_FAST" = 1 ]; then
    say "test clock: +1500 blocks and +7500 s (three epochs of stake history)"
    KEY=test1 callq "$KV3" AdvanceTestHeight 1500 || fail "AdvanceTestHeight"
    KEY=test1 callq "$KV3" AdvanceTestClock 7500 || fail "AdvanceTestClock"
    crank_to answered
    say "test clock: +72 h (the undisputed settlement delay)"
    KEY=test1 callq "$KV3" AdvanceTestClock 259300 || fail "AdvanceTestClock"
    crank_to settled
    KEY=test1 callq "$KOURT" Invoke reclaim "$DID" || true
    say "Kourt says: $(qeval "$KV3.ClaimStatus(\"gnoracle\", $CLAIM)" | tr -d '()' | sed 's/ string$//')"
    say "float now $(qeval "$KV3.CoinBalanceOf(\"gnoracle\", \"$KADDR\")" | num) micro-CC"
  else
    say "Kourt's clock is real here: the bot cranks the mirror hourly; the answer follows ~3 h of blocks and the settlement 72 h later"
  fi
}

links() {
  step "inspect on gnoweb $WEBURL (everything is still running; make demo-stop ends what the demo started)"
  cat <<LINKS | tee "$OUT/links.txt"
   gnoweb home         $WEBURL/r/clockwork/gnoracle/core
   feed and rounds     $WEBURL/r/clockwork/gnoracle/core:feed/$FEED      $WEBURL/r/clockwork/gnoracle/core:feed/$FEED/rounds
   providers           $WEBURL/r/clockwork/gnoracle/core:provider/$FEED/$(addr_of demo1)
   the reader realm    $WEBURL/r/clockwork/gnoracle/demo/reader      (subscribers: $WEBURL/r/clockwork/gnoracle/core:feed/$FEED/subscribers)
   the dispute         $WEBURL/r/clockwork/gnoracle/core:dispute/$DID      (all: $WEBURL/r/clockwork/gnoracle/core:disputes)
   the DAO             $WEBURL/r/clockwork/gnoracle/dao:members      $WEBURL/r/clockwork/gnoracle/dao:member/$(addr_of voter1)
   Kourt mirror        $WEBURL/r/clockwork/gnoracle/kourt:dispute/$DID
   the court on Kourt  $WEBURL/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3:gnoracle      claim: $WEBURL/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3:gnoracle/${CLAIM:-1}
   health              $WEBURL/r/clockwork/gnoracle/core:health      $WEBURL/r/clockwork/gnoracle/dao:health
   logs                $OUT (agents, bot, reader-poll.log, gnodev.log when the demo started the chain)
LINKS
}

main() {
  preflight
  ensure_chain
  accept_releases
  arm_kourt_clock
  dev_clocks
  keys_and_funding
  members
  create_feed
  write_configs
  start_workers
  live_phase
  results
  open_dispute
  vote
  mirror_to_kourt
  links
  echo
  echo "demo: done in $((SECONDS / 60)) min $((SECONDS % 60)) s"
}

case "${1:-}" in
  poll) poll_loop "$2" "$3" ;;
  stop) stop_all ;;
  "") main ;;
  *) echo "usage: $0 [poll <feed> <every> | stop]" >&2; exit 2 ;;
esac

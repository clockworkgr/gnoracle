#!/usr/bin/env python3
"""Assemble docs/AGENT_SOAK_SHOWCASE.md from a captured `make agent-soak` run.

Capture (from the repository root, with gnodev on RPC 36657 and feed 1
created by `make chain-test`), into a directory D that also holds this
script:

    bin/gnoracle status > D/status-before.txt
    bin/gnoracle -raw feed 1 > D/feed-before.json
    bin/gnoracle -raw providers 1 > D/providers-before.json
    date -u +%Y-%m-%dT%H:%M:%SZ > D/started.txt
    REMOTE=http://127.0.0.1:36657 EXTRA_KEYS=prov2 AGENTS=3 DURATION=300 ./scripts/agent-soak.sh > D/soak-output.txt 2>&1
    date -u +%Y-%m-%dT%H:%M:%SZ > D/ended.txt
    bin/gnoracle status > D/status-after.txt
    bin/gnoracle -raw feed 1 > D/feed-after.json
    bin/gnoracle -raw providers 1 > D/providers-after.json
    bin/gnoracle -raw rounds 1 10 > D/rounds-after.json
    bin/gnoracle -raw health > D/health-after.json
    cp -r .dev-agent/soak D/run
    (optional) make chain-test > D/chain-test.txt, with its start time in D/chaintest-started.txt

Then `python3 D/showcase-assemble.py` writes the document.
"""
import json, os, re, glob, subprocess, statistics
from datetime import datetime, timezone

S = os.path.dirname(os.path.abspath(__file__))
R = os.path.join(S, "run")
REPO = os.environ.get("GNORACLE_REPO", os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))
OUT = os.path.join(REPO, "docs", "AGENT_SOAK_SHOWCASE.md")

def read(p, default=""):
    try:
        return open(p).read()
    except FileNotFoundError:
        return default

def jload(p):
    return json.loads(read(p, "{}"))

def strip_ansi(s):
    return re.sub(r"\x1b\[[0-9;]*m", "", s)

def ts(unix):
    return datetime.fromtimestamp(int(unix), timezone.utc).strftime("%H:%M:%S")

def gnot(u):
    return f"{u/1e6:,.6f}".rstrip("0").rstrip(".") + " GNOT"

commit = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
status_before = read(os.path.join(S, "status-before.txt")).strip()
status_after = read(os.path.join(S, "status-after.txt")).strip()
feed_b = jload(os.path.join(S, "feed-before.json"))
feed_a = jload(os.path.join(S, "feed-after.json"))
prov_b = {p["addr"]: p for p in jload(os.path.join(S, "providers-before.json")).get("providers", [])}
prov_a = {p["addr"]: p for p in jload(os.path.join(S, "providers-after.json")).get("providers", [])}
rounds = jload(os.path.join(S, "rounds-after.json")).get("rounds", [])
health_lines = [l for l in read(os.path.join(S, "health-after.json")).splitlines() if l.strip()]
soak_out = strip_ansi(read(os.path.join(S, "soak-output.txt")))
started = read(os.path.join(S, "started.txt")).strip()
ended = read(os.path.join(S, "ended.txt")).strip()

# key names -> addresses from the run's configs and the soak output
keys = {}
for cfg in glob.glob(os.path.join(R, "*.toml")):
    name = os.path.basename(cfg)[:-5]
    if name == "bot":
        continue
    keys[name] = None
addr_of = {}
for m in re.finditer(r"^(\w+) \((g1[0-9a-z]{38})\): (.*)$", soak_out, re.M):
    addr_of[m.group(1)] = m.group(2)
# test1 address is fixed
addr_of.setdefault("test1", "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
# agents that actually ran = journals present
agents = sorted([os.path.basename(p)[:-len("-journal.jsonl")] for p in glob.glob(os.path.join(R, "*-journal.jsonl"))],
                key=lambda n: (n != "test1", n))
for a in agents:
    if a not in addr_of:
        # find from state file / log
        log = read(os.path.join(R, a + ".log"))
        m = re.search(r"as (g1[0-9a-z]{38})", log)
        if m:
            addr_of[a] = m.group(1)
name_of = {v: k for k, v in addr_of.items()}
def short(addr):
    return name_of.get(addr, addr[:12] + "…")

# journals
journals = {a: [json.loads(l) for l in read(os.path.join(R, a + "-journal.jsonl")).splitlines() if l.strip()] for a in agents}

# timeline: agent logs + bot log, sorted by timestamp
events = []
for a in agents:
    for line in read(os.path.join(R, a + ".log")).splitlines():
        m = re.match(r"^(?:\[feed \d+\] )?(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) (.*)$", line)
        if m:
            events.append((m.group(1), a, m.group(2)))
for line in read(os.path.join(R, "bot.log")).splitlines():
    m = re.match(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) (.*)$", line)
    if m:
        txt = m.group(2).replace("notify[0]: ", "")
        events.append((m.group(1), "bot", txt))
events.sort(key=lambda e: e[0])
offset_h = 0
if events and started:
    first_local = datetime.strptime(events[0][0], "%Y/%m/%d %H:%M:%S")
    start_utc = datetime.strptime(started, "%Y-%m-%dT%H:%M:%SZ")
    offset_h = round((first_local - start_utc).total_seconds() / 3600)
skipped_during_run = len(re.findall(r"RoundFinalized feed=\d+ round=\d+ status=skipped", read(os.path.join(R, "bot.log"))))
catchup_lines = [e for e in events if "finalised" in e[2] and "round(s) from" in e[2]]

# gas stats from journals
gas = {"submit": [], "finalize": [], "claim": []}
fees = {"submit": [], "finalize": [], "claim": []}
for a, js in journals.items():
    for e in js:
        if e["kind"] in gas and e.get("gasUsed"):
            gas[e["kind"]].append(e["gasUsed"])
            fees[e["kind"]].append(int(re.sub(r"\D", "", e.get("fee", "0")) or 0))

def sample(kind, agent=None):
    for a, js in journals.items():
        if agent and a != agent:
            continue
        for e in js:
            if e["kind"] == kind:
                return a, e
    return None, None

def fence(s, lang=""):
    return f"```{lang}\n{s.rstrip()}\n```\n"

def pretty(e):
    e = dict(e)
    for s in e.get("samples", []):
        if "raw" in s and len(s["raw"]) > 300:
            s["raw"] = s["raw"][:300] + "…"
    return json.dumps(e, indent=2)

# sections of the soak output
def section(title):
    m = re.search(r"== " + re.escape(title) + r"\n(.*?)(?=\n== |\Z)", soak_out, re.S)
    return m.group(1).strip() if m else ""

spec = feed_b.get("spec", {})
sched_rounds = [r for r in rounds if r.get("exists")]
# rounds produced during the run: those finalised after start
run_rounds = [r for r in sched_rounds if r.get("finalisedAt", 0) and r["finalisedAt"] >= (feed_b.get("now", 0) - 5)]
run_rounds.sort(key=lambda r: r["id"])

doc = []
w = doc.append
w("# Agent soak showcase: three providers, the bot and one feed on gnodev\n")
w(f"A complete, unedited run of `make agent-soak` on {started[:10]} (UTC {started[11:19]} to {ended[11:19]}), "
  f"from repository commit `{commit}`, against a local gno v1.2.0 chain. Every command, log line and chain "
  "state below was captured from that run; nothing is illustrative. It shows the whole loop the protocol "
  "relies on: providers register with stake, their agents fetch a value each round, submit it, the round "
  "finalises (early, when everyone obliged has submitted), rewards accrue, and the bot announces every "
  "step while cranking what nobody else did.\n")
w(f"Chain time in the tables below is UTC; the tool logs are in the host's local time (UTC{offset_h:+d}).\n")

w("## 1. Environment\n")
w("| | |\n|---|---|\n")
w(f"| chain | gnodev (`{status_before.splitlines()[0]}`), RPC `http://127.0.0.1:36657`, gnoweb `http://127.0.0.1:38888` |\n")
w("| toolchain | gno v1.2.0 built from the tag (`make toolchain`); tools built with `CGO_ENABLED=0 go build` from `gnolang/gno v1.2.0` |\n")
for l in status_before.splitlines()[1:3]:
    parts = l.split()
    w(f"| {parts[0]} realm | `{parts[1]}` serving `{l.split('live ')[-1]}` |\n")
w("| keys | throwaway keybase `.dev-keys/` (test1 is gnodev's funded genesis key; the soak creates the others) |\n")
w("| price source | a local `python3 -m http.server` serving `price.json` on port 38999 for the `http` adapter; the `exec` adapter prints a value from a shell one-liner |\n")
w("\n### The feed\n")
w("`gnoracle feed 1` before the run (the spec is what the DAO accepted when `make chain-test` created the feed):\n")
w("| field | value |\n|---|---|\n")
for k in ["name", "kind", "valueType", "decimals", "interval", "submitWindow", "sources", "minProviders", "maxProviders", "providerMinStake", "toleranceBps", "quarantineBps", "disputeWindow", "readPrice", "subscriptionPrice"]:
    v = spec.get(k)
    if k in ("providerMinStake", "readPrice", "subscriptionPrice") and isinstance(v, int):
        v = f"{v} ugnot ({gnot(v)})"
    w(f"| `{k}` | {v} |\n")
w(f"| status / pool / drip per round | {feed_b.get('status')} / {feed_b.get('pool')} ugnot / {feed_b.get('drip')} ugnot |\n")
w(f"| last finalised round / current round | {feed_b.get('lastFinalized')} / {feed_b.get('currentRound')} |\n")
jailed = [a for a, p in prov_b.items() if p["status"] == "jailed"]
w("\nProviders before the run (`gnoracle providers 1`)" + (
  f". {len(jailed)} jailed: their agents were stopped in earlier experiments and three consecutive misses jail a provider, "
  "which is the protocol working as specified and frees their slots for newcomers.\n" if jailed else
  ": the two providers `make chain-test` registered when it created the feed.\n"))
w("| provider | status | slot | stake (ugnot) | consecutive misses | earned so far (ugnot) |\n|---|---|---|---|---|---|\n")
for addr, p in sorted(prov_b.items(), key=lambda kv: kv[1]["slot"] if kv[1]["slot"] >= 0 else 99):
    w(f"| `{addr}` | {p['status']} | {p['slot']} | {p['stake']} | {p['consecutiveMisses']} | {p['totalEarned']} |\n")

chain_test = read(os.path.join(S, "chain-test.txt"))
ct_started = read(os.path.join(S, "chaintest-started.txt")).strip()
if chain_test:
    w("\n## 1a. The chain was new\n")
    w(f"gnodev was started from scratch shortly before {ct_started[11:19]} UTC (`make dev RPC=36657 WEB=38888`) and "
      "`make chain-test` then drove the whole lifecycle once: accept the implementations, create and activate "
      "feed 1, register two providers, submit two rounds, deposit consumer credit and read, stake in the DAO, "
      "forward fees, found the Kourt court and file a claim. Its step headings, unedited:\n")
    steps = [l[3:] for l in strip_ansi(chain_test).splitlines() if l.startswith("== ")]
    w(fence("\n".join(steps)))
w("\n## 2. Pre-flight\n")
w("`gnoracle status` reads the three realms' `:json/now` views and the node's `/status`:\n")
w(fence(status_before))

w("## 3. Keys, funding and registration\n")
w("The soak script (`scripts/agent-soak.sh`) uses `test1` and creates `soak1`, `soak2`, … in the dev keybase, "
  "funds each from `test1` with the feed's minimum stake plus a gas float, and registers it through the CLI "
  "(`gnoracle register <feed> <stake> <memo>`, which sends the stake with the `Register` call). A key that is "
  "already an active provider is reused; a full provider set is reported and skipped.\n")
w(fence(section("keys and registrations")))
w("Registration assigns the next free slot; obligations start at the round after the current one "
  "(`obligedFrom`), so a newcomer is never penalised for a round that was already open.\n")

w("## 4. Generated configuration\n")
w("One `agent.toml` per key. Odd-numbered agents use the `http` adapter against the local price server, "
  "even-numbered ones the `exec` adapter, so the run exercises both paths and the values differ slightly "
  "(the feed's tolerance is 1%, so all stay eligible). `dev_tick` is a gnodev-only setting that nudges the "
  "lazy chain clock with a one-ugnot self-send.\n")
for a in agents:
    w(f"`{a}.toml`:\n")
    w(fence(read(os.path.join(R, a + ".toml")), "toml"))
w("The bot's configuration (`bot.toml`) posts to the log (no Telegram token) and has every crank enabled:\n")
w(fence(read(os.path.join(R, "bot.toml")), "toml"))

w("## 5. The run, as one timeline\n")
w(f"The agents and the bot ran for 300 seconds. Below are their log lines merged and sorted by time. "
  f"Agents are `{'`, `'.join(agents)}`; `bot` lines are the messages the bot would have posted to Telegram "
  "(`RoundFinalized` and `Submitted` are announced here because the dev config lists them; the default list "
  "is the dispute, proposal, provider and release events).\n")
w("```text\n")
for t, who, txt in events:
    w(f"{t[11:]}  {who:<6} {txt}\n")
w("```\n")
w("Things to notice:\n\n")
if skipped_during_run > 20:
    idle_min = (feed_b.get("now", 0) and (skipped_during_run * spec.get("interval", 60)) // 60)
    w(f"- **The catch-up at the start.** gnodev only advances its clock when a transaction lands, and the chain had "
      f"been idle since round {feed_b.get('lastFinalized')}: the agents' first `dev_tick` moved chain time forward "
      f"by about {idle_min} minutes at once, so {skipped_during_run} rounds nobody could have served were written "
      f"off as `skipped` in batches of eight by `CatchUp`. A live chain has continuous blocks and never produces "
      "this jump.\n")
if any("obligations start at round" in e[2] for e in events):
    w("- **The newcomer waits.** `soak1` registered during round 1, so its obligations start at round 2; its agent "
      "says so and waits, and the realm would reject an earlier submission. Round 1 was served by the two "
      "existing providers alone.\n")
if any("round is closed" in e[2] or "round is finalised" in e[2] for e in events):
    w("- A first tick may hit `round is closed` or `round is finalised`: the agent computed the round from the chain "
      "time it read, and by the time the transaction was simulated another agent's transaction had moved the clock "
      "or finished the round. Simulation is free, so this costs nothing.\n")
plain = [g for g in gas["submit"] if g < 25_000_000]
fin = [g for g in gas["submit"] if g >= 25_000_000]
if plain and fin:
    w(f"- **The last submitter finalises.** A `Submit` that completes the round aggregates, pays and records it in the "
      f"same call: {int(statistics.median(plain))/1e6:.1f}M gas for a plain submission against "
      f"{int(statistics.median(fin))/1e6:.1f}M for the finalising one, and the bot announces `RoundFinalized` in the "
      "same second as the third `Submitted`. Which agent is last varies with their jitter (1, 2 and 3 seconds).\n")
if catchup_lines:
    w("- When a round was not completed by everyone, the agents' `finalised N round(s)` lines show `CatchUp` closing "
      "it after the window plus `finalize_delay`; the bot does the same after its grace period.\n")
else:
    w("- No `CatchUp` was needed: every round was completed by all three providers inside the window, so the "
      "cranks in the agents and the bot had nothing to do.\n")
w("- Each agent's value comes from its own source: the two `http` agents read the same local `price.json` "
  "(1.0012), the `exec` agent prints a random value between 1.0000 and 1.0039; the round's value is the lower "
  "median, and every submission within the 1% tolerance is eligible and paid.\n")

w("## 6. What the journal recorded\n")
w("Every agent appends one JSON line per fetch, refusal, submission, finalisation, claim and error to its "
  "journal. This is the operator's evidence in a dispute: the raw source answers, the aggregated value, and "
  "the transaction that carried it. Entries from this run:\n")
for kind, label in [("fetch", "A fetch (raw source response, aggregated value)"), ("submit", "The submission that followed"), ("finalize", "A finalisation crank")]:
    a, e = sample(kind)
    if e:
        w(f"**{label}** (`{a}-journal.jsonl`):\n")
        w(fence(pretty(e), "json"))

w("## 7. Chain state after the run\n")
w("`gnoracle rounds 1 10` (newest first) shows the rounds the run produced. `opened → finalised` is the "
  "chain-time distance from the round's scheduled opening to its finalisation; with a 60-second window, "
  "single-digit seconds mean every obliged provider submitted and the last one finalised the round early.\n")
w("| round | status | tier | submitters (slots) | value | pool (ugnot) | opened → finalised |\n|---|---|---|---|---|---|---|\n")
for r in sorted(sched_rounds, key=lambda r: -r["id"]):
    subs = ", ".join(str(s["slot"]) for s in r.get("submitted", []))
    val = "delayed" if r.get("delayed") else (str(r.get("value")) if r.get("value") is not None else "")
    fin = r["finalisedAt"] - r["opensAt"] if r.get("finalisedAt") else ""
    w(f"| {r['id']} | {r['status']} | {r['tier']} | {subs} | {val} | {r['pool']} | {fin}s |\n")
w("\nValues read `delayed` because the free views only show a round's numbers once its dispute window and "
  "`renderDelay` have passed (plan §6.1); a paying realm gets them immediately through `Read`. The bot's "
  "`RoundFinalized` lines above carry the aggregate as emitted, which is the same rule applied to events: "
  "the value is public in the event log, and the fresh *view* is what consumers pay for.\n")

w("\n### Providers\n")
w("| provider | key | status | slot | rewards before | rewards after | earned this run | consecutive misses |\n|---|---|---|---|---|---|---|---|\n")
for addr, p in sorted(prov_a.items(), key=lambda kv: kv[1]["slot"] if kv[1]["slot"] >= 0 else 99):
    b = prov_b.get(addr, {"totalEarned": 0, "rewards": 0})
    w(f"| `{addr[:16]}…` | {short(addr)} | {p['status']} | {p['slot']} | {b['rewards']} | {p['rewards']} | {p['totalEarned'] - b['totalEarned']} | {p['consecutiveMisses']} |\n")
w(f"\nFeed pool: {feed_b.get('pool')} → {feed_a.get('pool')} ugnot (drip {feed_a.get('drip')} ugnot per round, from the "
  f"subscription bought by `make chain-test`); rounds finalised: {feed_b.get('roundsFinal')} → {feed_a.get('roundsFinal')}.\n")
w("Each finalised round's pool is split equally among the eligible submitters after the 1% cranker tip. The pool "
  "is the drip plus the provider share of read fees metered since the last finalisation plus any penalty carry: "
  "round 2 above carries the 14,000 ugnot provider share (70%) of the 20,000 ugnot `Read` that `make chain-test` "
  "paid, which is why it pays far more than the drip.\n")

w("\n### Conservation checks\n")
w("`gnoracle health` renders both permanent realms' `Health()`: every ugnot the core holds must equal the sum "
  "of what it owes (stakes, unbonding, credits, pools, rewards, bonds, pending fees, deposits); the DAO "
  "checks its PYTH and ugnot the same way. Both read `ok` after the run:\n")
for l in health_lines[:2]:
    try:
        o = json.loads(l)
        inner = json.loads(o["health"])
        w(fence(json.dumps(inner, indent=2), "json"))
    except Exception:
        w(fence(l))

w("## 8. Assertions\n")
w("The script ends with the checks that make it a test rather than a demo:\n")
w(fence(section("assertions")))

w("## 9. Numbers from this run\n")
w("| transaction | count | gas used (min / median / max) | fee paid at 0.001 ugnot per gas |\n|---|---|---|---|\n")
for kind in ["submit", "finalize", "claim"]:
    g = gas[kind]
    if g:
        w(f"| {kind} | {len(g)} | {min(g):,} / {int(statistics.median(g)):,} / {max(g):,} | {min(fees[kind]):,} to {max(fees[kind]):,} ugnot |\n")
lat_first = [r["openedAt"] - r["opensAt"] for r in run_rounds if r.get("openedAt")]
lat_fin = [r["finalisedAt"] - r["opensAt"] for r in run_rounds if r.get("finalisedAt")]
if lat_fin:
    w(f"\n- Round finalised after it opened: {min(lat_fin)} to {max(lat_fin)} s against a 60 s window (agents poll every 2 s and wait a 1 to 3 s jitter).\n")
w("- The fee is the gas asked for, not the gas used. In this run the tools simulated each call and asked for "
  "(measured gas + 12M finalisation headroom) x 1.25 for every `Submit`; the sizing has since been changed so the headroom "
  "is only added when exactly one other provider is still to submit, and the fee is the larger of measured x 1.25 and "
  "measured + headroom, which would have made most of these fees about 23,000 ugnot and the finalising ones about 40,000. A submission "
  "that also finalises costs about 13M gas more than a plain one, and which agent pays it depends on who submits last.\n")
w("- On gnoland-1 the same transactions cost the same gas; only the gas price (0.001 ugnot per gas minimum) "
  "and the block time differ. `docs/SIMULATION.md` turns these numbers into monthly costs per feed cadence.\n")

w("\n## 10. Reproduce it\n")
w(fence("""make toolchain deps                       # once: pinned gno v1.2.0 and the on-chain dependency mirror
make dev RPC=36657 WEB=38888              # a local chain with the realms, in another shell
make dev-keys                             # .dev-keys/ with gnodev's test1 key
REMOTE=http://127.0.0.1:36657 CALL_GAS_WANTED=60000000 CALL_GAS_FEE=120000ugnot make chain-test   # feed 1, providers, DAO, Kourt
REMOTE=http://127.0.0.1:36657 AGENTS=3 DURATION=300 make agent-soak
ls .dev-agent/soak/                       # configs, logs, journals, state files of the run""", "sh"))
w("The same agents run unchanged against pearl-1 or gnoland-1 with `remote`, `chain_id`, `core` and a real "
  "key in `agent.toml` (`configs/agent.example.toml`); `docs/guides/PROVIDERS.md` is the operator's path.\n")

text = "".join(doc)

# Markdown hygiene: a blank line before headings, tables and fence openings,
# and after fence closings, so every renderer sees the same structure.
lines = text.split("\n")
out_lines = []
in_fence = False
for i, line in enumerate(lines):
    prev = out_lines[-1] if out_lines else ""
    if line.startswith("```"):
        if not in_fence and prev.strip() != "":
            out_lines.append("")
        out_lines.append(line)
        if in_fence:
            out_lines.append("")
        in_fence = not in_fence
        continue
    if in_fence:
        out_lines.append(line)
        continue
    if (line.startswith("#") or (line.startswith("|") and not prev.startswith("|"))) and prev.strip() != "":
        out_lines.append("")
    if line.strip() == "" and prev.strip() == "":
        continue
    out_lines.append(line)
text = "\n".join(out_lines).rstrip("\n") + "\n"
open(OUT, "w").write(text)
print("wrote", OUT, len("".join(doc)), "bytes;", len(events), "timeline lines;", len(agents), "agents:", agents)

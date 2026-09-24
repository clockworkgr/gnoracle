// gnoracle is the operator's command line for the Gnoracle realms: read the
// machine views, run provider and consumer transactions, and vote on
// disputes with the commit-reveal salt kept for you.
//
// Global flags (or environment): -remote/$GNORACLE_REMOTE, -chain/$GNORACLE_CHAIN,
// -ns/$GNORACLE_NS (derives the realm paths), -key-home/$GNORACLE_KEY_HOME,
// -key/$GNORACLE_KEY, -password-file/$GNORACLE_PASSWORD_FILE.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/clockworkgr/gnoracle/agent"
	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

type cli struct {
	remote, chain, ns, core, dao, kourt, token string
	keyHome, key, passwordFile                 string
	gasMode, gasPrice                          string
	gasWanted                                  int64
	send                                       string
	raw                                        bool
	client                                     *gnochain.Client
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

const usage = `gnoracle [flags] <command> [args]

Reads
  status                          chain time, live releases, counts
  feeds | feed <id> | round <feed> <round|current> | rounds <feed> [n]
  provider <feed> <addr> | providers <feed>
  dispute <id> | disputes | ballot <dispute> | member <addr> | proposal <id>
  params [core|dao] | health | kourt <dispute>
  subscribers <feed> | subscription <feed> <realm-path>
  commitment <dispute> <round> <choice> <salt> <voter>   compute a commitment offline

Provider (signs)
  register <feed> <stake> [memo]  stake in ugnot or GNOT (e.g. 10000gnot)
  topup <feed> <amount> | unbond <feed> | withdraw <feed> | unjail <feed> | claim <feed>
  submit <feed> <round|current> <value>   value in feed units (e.g. 1.2345) or an option label
  finalize <feed> [max-rounds]    CatchUp

Consumer, sponsor and requester (signs)
  subscribe <feed> <realm-path> <periods> <amount>   SubscribeRealm: the realm may Read the feed for the periods paid
  sponsor <feed> <periods> <amount>                  keep a feed funded (periods x subscriptionPrice)
  deposit <amount> [account]      DepositFor: prepaid balance of a realm requester (feed requests, bounties, subscriptions)
  propose-feed <spec.json> <deposit>
  dispute-open <feed> <round> <value> <minor|major> <evidence> <bond>
  appeal <dispute> <bond> | resolve <dispute>

DAO member (signs)
  stake <pyth> | unstake <pyth> | dao-withdraw | dao-claim | settle [addr]   (stake approves the DAO on the token first)
  commit <dispute> <UPHOLD|OVERTURN|OVERTURN_MINOR|VOID|ABSTAIN>   salt saved under ~/.gnoracle/votes; re-run to change the choice
  reveal <dispute>
  vote <proposal> <yes|no|abstain> | execute <proposal>   (choice is case-insensitive)
  propose <kind> <payload> <title> <deposit>

Anything
  call <pkgpath> <func> [args...]   with -send for coins
  kourt-crank <dispute>

Amounts: plain ugnot ("2500000000") or with a unit ("2500gnot", "1.5gnot").
`

func main() {
	c := &cli{}
	fs := flag.NewFlagSet("gnoracle", flag.ExitOnError)
	fs.StringVar(&c.remote, "remote", env("GNORACLE_REMOTE", "http://127.0.0.1:26657"), "RPC URL")
	fs.StringVar(&c.chain, "chain", env("GNORACLE_CHAIN", "dev"), "chain id")
	fs.StringVar(&c.ns, "ns", env("GNORACLE_NS", "clockwork"), "namespace the realms live under (gno.land/r/<ns>/gnoracle/...)")
	fs.StringVar(&c.core, "core", env("GNORACLE_CORE", ""), "core realm path (overrides -ns)")
	fs.StringVar(&c.dao, "dao", env("GNORACLE_DAO", ""), "dao realm path (overrides -ns)")
	fs.StringVar(&c.kourt, "kourt", env("GNORACLE_KOURT", ""), "kourt mirror realm path (overrides -ns)")
	fs.StringVar(&c.token, "token", env("GNORACLE_TOKEN", ""), "PYTH token realm path (overrides -ns)")
	fs.StringVar(&c.keyHome, "key-home", env("GNORACLE_KEY_HOME", ""), "gnokey keybase directory")
	fs.StringVar(&c.key, "key", env("GNORACLE_KEY", ""), "key name or address")
	fs.StringVar(&c.passwordFile, "password-file", env("GNORACLE_PASSWORD_FILE", ""), "file holding the key password (else $GNORACLE_KEY_PASSWORD)")
	fs.StringVar(&c.gasMode, "gas-mode", env("GNORACLE_GAS_MODE", "estimate"), "estimate | fixed")
	fs.Int64Var(&c.gasWanted, "gas-wanted", 60_000_000, "gas ceiling (fixed: gas asked)")
	fs.StringVar(&c.gasPrice, "gas-price", env("GNORACLE_GAS_PRICE", "0.001ugnot"), "ugnot per gas")
	fs.StringVar(&c.send, "send", "", "coins to send with a transaction, e.g. 1000000ugnot")
	fs.BoolVar(&c.raw, "raw", false, "print realm JSON as returned instead of indented")
	fs.Usage = func() { fmt.Fprint(os.Stderr, usage); fs.PrintDefaults() }
	_ = fs.Parse(os.Args[1:])
	if c.core == "" {
		c.core = "gno.land/r/" + c.ns + "/gnoracle/core"
	}
	if c.dao == "" {
		c.dao = "gno.land/r/" + c.ns + "/gnoracle/dao"
	}
	if c.kourt == "" {
		c.kourt = "gno.land/r/" + c.ns + "/gnoracle/kourt"
	}
	if c.token == "" {
		c.token = "gno.land/r/" + c.ns + "/gnoracle/token"
	}
	args := fs.Args()
	if len(args) == 0 {
		fs.Usage()
		os.Exit(2)
	}
	if err := c.run(args[0], args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func (c *cli) connect(sign bool) error {
	cfg := gnochain.Config{Remote: c.remote, ChainID: c.chain, Gas: gnochain.GasConfig{Mode: c.gasMode, Wanted: c.gasWanted, Price: c.gasPrice}}
	if sign {
		if c.key == "" && os.Getenv("GNORACLE_MNEMONIC") == "" {
			return errors.New("this command signs a transaction: set -key and -key-home (or GNORACLE_MNEMONIC)")
		}
		cfg.KeyHome, cfg.KeyName, cfg.PasswordFile = c.keyHome, c.key, c.passwordFile
	}
	cl, err := gnochain.New(cfg)
	if err != nil {
		return err
	}
	c.client = cl
	return nil
}

func (c *cli) view(pkg, path string) error {
	if err := c.connect(false); err != nil {
		return err
	}
	out, err := c.client.Render(pkg, "json/"+path)
	if err != nil {
		return err
	}
	if c.raw {
		fmt.Println(out)
		return nil
	}
	var buf bytes.Buffer
	if err := json.Indent(&buf, []byte(out), "", "  "); err != nil {
		fmt.Println(out)
		return nil
	}
	fmt.Println(buf.String())
	return nil
}

func (c *cli) tx(pkg, fn string, args ...string) error {
	if err := c.connect(true); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	res, err := c.client.Call(ctx, pkg, fn, gnochain.CallOpts{Send: c.send}, args...)
	if err != nil {
		return err
	}
	fmt.Printf("ok: %s.%s at height %d, tx %s, gas %d, fee %s\n", shortPkg(pkg), fn, res.Height, res.Hash, res.GasUsed, res.Fee)
	for _, r := range res.Results {
		fmt.Println("  →", r)
	}
	return nil
}

func shortPkg(p string) string {
	i := strings.LastIndex(p, "/gnoracle/")
	if i < 0 {
		return p
	}
	return p[i+len("/gnoracle/"):]
}

func need(args []string, n int, what string) error {
	if len(args) < n {
		return fmt.Errorf("usage: gnoracle %s", what)
	}
	return nil
}

// amount accepts ugnot integers or "<decimal>gnot".
func amount(s string) (string, error) {
	s = strings.ToLower(strings.TrimSpace(s))
	if strings.HasSuffix(s, "gnot") && !strings.HasSuffix(s, "ugnot") {
		r, ok := new(big.Rat).SetString(strings.TrimSuffix(s, "gnot"))
		if !ok {
			return "", fmt.Errorf("bad amount %q", s)
		}
		v, err := agent.ScaleToInt(r, 6)
		if err != nil {
			return "", err
		}
		return strconv.FormatInt(v, 10) + "ugnot", nil
	}
	s = strings.TrimSuffix(s, "ugnot")
	if _, err := strconv.ParseInt(s, 10, 64); err != nil {
		return "", fmt.Errorf("bad amount %q: use ugnot or e.g. 2500gnot", s)
	}
	return s + "ugnot", nil
}

func (c *cli) feedValue(feed uint64, text string) (int64, *gnochain.FeedInfo, error) {
	if err := c.connect(false); err != nil {
		return 0, nil, err
	}
	f, err := c.client.Feed(c.core, feed)
	if err != nil {
		return 0, nil, err
	}
	if f.Spec.IsNumeric() {
		r, ok := new(big.Rat).SetString(text)
		if !ok {
			return 0, nil, fmt.Errorf("%q is not a number", text)
		}
		v, err := agent.ScaleToInt(r, f.Spec.Decimals)
		return v, f, err
	}
	v, err := agent.OptionIndex(f.Spec.Options, text, nil)
	return v, f, err
}

func (c *cli) roundArg(feed uint64, s string) (uint64, error) {
	if s != "current" {
		return strconv.ParseUint(s, 10, 64)
	}
	if err := c.connect(false); err != nil {
		return 0, err
	}
	f, err := c.client.Feed(c.core, feed)
	if err != nil {
		return 0, err
	}
	if f.CurrentRound == nil {
		return 0, fmt.Errorf("feed %d has not started (first round at %d)", feed, f.StartAt)
	}
	return *f.CurrentRound, nil
}

func (c *cli) run(cmd string, a []string) error {
	pu := func(s string) uint64 { v, _ := strconv.ParseUint(s, 10, 64); return v }
	switch cmd {
	// ---- reads
	case "status":
		if err := c.connect(false); err != nil {
			return err
		}
		st, err := c.client.Status(context.Background())
		if err != nil {
			return err
		}
		fmt.Printf("chain %s height %d time %s\n", st.ChainID, st.Height, st.Time.UTC().Format(time.RFC3339))
		if h, err := c.client.CoreNow(c.core); err == nil {
			fmt.Printf("core  %s now %d live %s\n", c.core, h.Now, h.Live)
		} else {
			fmt.Printf("core  %s: %v\n", c.core, err)
		}
		if d, err := c.client.DAONow(c.dao); err == nil {
			fmt.Printf("dao   %s address %s epoch %d staked %d members %d proposals %d ballots %d live %s\n", c.dao, d.Address, d.Epoch, d.TotalStaked, d.MemberCount, d.ProposalCount, d.BallotCount, d.Live)
		} else {
			fmt.Printf("dao   %s: %v\n", c.dao, err)
		}
		if out, err := c.client.Render(c.kourt, "json/now"); err == nil {
			fmt.Printf("kourt %s %s\n", c.kourt, out)
		}
		return nil
	case "feeds":
		return c.view(c.core, "feeds")
	case "feed":
		if err := need(a, 1, "feed <id>"); err != nil {
			return err
		}
		return c.view(c.core, "feed/"+a[0])
	case "round":
		if err := need(a, 2, "round <feed> <round|current>"); err != nil {
			return err
		}
		return c.view(c.core, "feed/"+a[0]+"/round/"+a[1])
	case "rounds":
		if err := need(a, 1, "rounds <feed> [n]"); err != nil {
			return err
		}
		n := "20"
		if len(a) > 1 {
			n = a[1]
		}
		return c.view(c.core, "feed/"+a[0]+"/rounds/"+n)
	case "provider":
		if err := need(a, 2, "provider <feed> <addr>"); err != nil {
			return err
		}
		return c.view(c.core, "feed/"+a[0]+"/provider/"+a[1])
	case "providers":
		if err := need(a, 1, "providers <feed>"); err != nil {
			return err
		}
		return c.view(c.core, "feed/"+a[0]+"/providers")
	case "dispute":
		if err := need(a, 1, "dispute <id>"); err != nil {
			return err
		}
		return c.view(c.core, "dispute/"+a[0])
	case "disputes":
		return c.view(c.core, "disputes")
	case "ballot":
		if err := need(a, 1, "ballot <dispute>"); err != nil {
			return err
		}
		return c.view(c.dao, "ballot/dispute/"+a[0])
	case "member":
		if err := need(a, 1, "member <addr>"); err != nil {
			return err
		}
		return c.view(c.dao, "member/"+a[0])
	case "proposal":
		if err := need(a, 1, "proposal <id>"); err != nil {
			return err
		}
		return c.view(c.dao, "proposal/"+a[0])
	case "params":
		if len(a) > 0 && a[0] == "dao" {
			return c.view(c.dao, "params")
		}
		return c.view(c.core, "params")
	case "health":
		if err := c.view(c.core, "health"); err != nil {
			return err
		}
		return c.view(c.dao, "health")
	case "kourt":
		if err := need(a, 1, "kourt <dispute>"); err != nil {
			return err
		}
		return c.view(c.kourt, "record/"+a[0])
	case "subscribers":
		if err := need(a, 1, "subscribers <feed>"); err != nil {
			return err
		}
		return c.view(c.core, "feed/"+a[0]+"/subscribers")
	case "subscription":
		if err := need(a, 2, "subscription <feed> <realm-path>"); err != nil {
			return err
		}
		return c.view(c.core, "feed/"+a[0]+"/subscription/"+a[1])
	case "commitment":
		if err := need(a, 5, "commitment <dispute> <round> <choice> <salt> <voter>"); err != nil {
			return err
		}
		round, _ := strconv.Atoi(a[1])
		fmt.Println(gnochain.Commitment(pu(a[0]), round, a[2], a[3], a[4]))
		return nil

	// ---- provider
	case "register":
		if err := need(a, 2, "register <feed> <stake> [memo]"); err != nil {
			return err
		}
		stake, err := amount(a[1])
		if err != nil {
			return err
		}
		memo := ""
		if len(a) > 2 {
			memo = strings.Join(a[2:], " ")
		}
		c.send = stake
		return c.tx(c.core, "Register", a[0], memo)
	case "topup":
		if err := need(a, 2, "topup <feed> <amount>"); err != nil {
			return err
		}
		amt, err := amount(a[1])
		if err != nil {
			return err
		}
		c.send = amt
		return c.tx(c.core, "TopUp", a[0])
	case "unbond":
		if err := need(a, 1, "unbond <feed>"); err != nil {
			return err
		}
		return c.tx(c.core, "RequestUnbond", a[0])
	case "withdraw":
		if err := need(a, 1, "withdraw <feed>"); err != nil {
			return err
		}
		return c.tx(c.core, "Withdraw", a[0])
	case "unjail":
		if err := need(a, 1, "unjail <feed>"); err != nil {
			return err
		}
		return c.tx(c.core, "Unjail", a[0])
	case "claim":
		if err := need(a, 1, "claim <feed>"); err != nil {
			return err
		}
		return c.tx(c.core, "ClaimRewards", a[0])
	case "submit":
		if err := need(a, 3, "submit <feed> <round|current> <value>"); err != nil {
			return err
		}
		feed := pu(a[0])
		round, err := c.roundArg(feed, a[1])
		if err != nil {
			return err
		}
		v, f, err := c.feedValue(feed, a[2])
		if err != nil {
			return err
		}
		fmt.Printf("submitting %s = %d to feed %d round %d\n", a[2], v, feed, round)
		_ = f
		return c.tx(c.core, "Submit", strconv.FormatUint(feed, 10), strconv.FormatUint(round, 10), strconv.FormatInt(v, 10))
	case "finalize":
		if err := need(a, 1, "finalize <feed> [max-rounds]"); err != nil {
			return err
		}
		n := "0"
		if len(a) > 1 {
			n = a[1]
		}
		return c.tx(c.core, "CatchUp", a[0], n)

	// ---- consumer / requester
	case "deposit":
		if err := need(a, 1, "deposit <amount> [account]"); err != nil {
			return err
		}
		amt, err := amount(a[0])
		if err != nil {
			return err
		}
		if err := c.connect(true); err != nil {
			return err
		}
		consumer := c.client.Bech32()
		if len(a) > 1 {
			consumer = a[1]
		}
		c.send = amt
		return c.tx(c.core, "DepositFor", consumer)
	case "subscribe":
		if err := need(a, 4, "subscribe <feed> <realm-path> <periods> <amount>"); err != nil {
			return err
		}
		amt, err := amount(a[3])
		if err != nil {
			return err
		}
		c.send = amt
		return c.tx(c.core, "SubscribeRealm", a[0], a[1], a[2])
	case "propose-feed":
		if err := need(a, 2, "propose-feed <spec.json> <deposit>"); err != nil {
			return err
		}
		spec, err := os.ReadFile(a[0])
		if err != nil {
			return err
		}
		if !json.Valid(spec) {
			return errors.New("spec is not valid JSON")
		}
		dep, err := amount(a[1])
		if err != nil {
			return err
		}
		c.send = dep
		return c.tx(c.core, "ProposeFeed", string(spec))
	case "sponsor":
		if err := need(a, 3, "sponsor <feed> <periods> <amount>"); err != nil {
			return err
		}
		amt, err := amount(a[2])
		if err != nil {
			return err
		}
		c.send = amt
		return c.tx(c.core, "Sponsor", a[0], a[1])
	case "dispute-open":
		if err := need(a, 6, "dispute-open <feed> <round> <value> <minor|major> <evidence> <bond>"); err != nil {
			return err
		}
		v, _, err := c.feedValue(pu(a[0]), a[2])
		if err != nil {
			return err
		}
		bond, err := amount(a[5])
		if err != nil {
			return err
		}
		c.send = bond
		return c.tx(c.core, "Dispute", a[0], a[1], strconv.FormatInt(v, 10), a[3], a[4])
	case "appeal":
		if err := need(a, 2, "appeal <dispute> <bond>"); err != nil {
			return err
		}
		bond, err := amount(a[1])
		if err != nil {
			return err
		}
		c.send = bond
		return c.tx(c.core, "Appeal", a[0])
	case "resolve":
		if err := need(a, 1, "resolve <dispute>"); err != nil {
			return err
		}
		return c.tx(c.core, "ResolveDispute", a[0])

	// ---- DAO
	case "stake":
		if err := need(a, 1, "stake <pyth>"); err != nil {
			return err
		}
		// the DAO pulls the tokens, so it must be approved on the token first
		if err := c.connect(false); err != nil {
			return err
		}
		head, err := c.client.DAONow(c.dao)
		if err != nil {
			return err
		}
		if head.Address == "" {
			return errors.New("the DAO view does not report its address; approve it on the token by hand")
		}
		if err := c.tx(c.token, "Approve", head.Address, pyth(a[0])); err != nil {
			return fmt.Errorf("approve: %w", err)
		}
		return c.tx(c.dao, "Stake", pyth(a[0]))
	case "unstake":
		if err := need(a, 1, "unstake <pyth>"); err != nil {
			return err
		}
		return c.tx(c.dao, "RequestUnstake", pyth(a[0]))
	case "dao-withdraw":
		return c.tx(c.dao, "Withdraw")
	case "dao-claim":
		if err := c.tx(c.dao, "ClaimFees"); err != nil {
			return err
		}
		return c.tx(c.dao, "ClaimRewards")
	case "settle":
		if err := c.connect(true); err != nil {
			return err
		}
		who := c.client.Bech32()
		if len(a) > 0 {
			who = a[0]
		}
		return c.tx(c.dao, "SettleMember", who, "0")
	case "commit":
		return c.commit(a)
	case "reveal":
		return c.reveal(a)
	case "vote":
		if err := need(a, 2, "vote <proposal> <yes|no|abstain>"); err != nil {
			return err
		}
		return c.tx(c.dao, "Vote", a[0], strings.ToUpper(a[1])) // the realm accepts YES, NO, ABSTAIN
	case "execute":
		if err := need(a, 1, "execute <proposal>"); err != nil {
			return err
		}
		return c.tx(c.dao, "Execute", a[0])
	case "propose":
		if err := need(a, 4, "propose <kind> <payload> <title> <deposit>"); err != nil {
			return err
		}
		dep, err := amount(a[3])
		if err != nil {
			return err
		}
		c.send = dep
		return c.tx(c.dao, "Propose", a[0], a[1], a[2])

	// ---- anything
	case "call":
		if err := need(a, 2, "call <pkgpath> <func> [args...]"); err != nil {
			return err
		}
		return c.tx(a[0], a[1], a[2:]...)
	case "kourt-crank":
		if err := need(a, 1, "kourt-crank <dispute>"); err != nil {
			return err
		}
		return c.tx(c.kourt, "Crank", a[0])
	case "help", "-h", "--help":
		fmt.Print(usage)
		return nil
	}
	return fmt.Errorf("unknown command %q (gnoracle help)", cmd)
}

// pyth scales a PYTH amount (6 decimals) unless it is already an integer of
// base units suffixed with "u".
func pyth(s string) string {
	if strings.HasSuffix(s, "u") {
		return strings.TrimSuffix(s, "u")
	}
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		return s
	}
	v, err := agent.ScaleToInt(r, 6)
	if err != nil {
		return s
	}
	return strconv.FormatInt(v, 10)
}

// voteRecord is the salt file written by commit and read by reveal.
type voteRecord struct {
	Chain      string `json:"chain"`
	Dispute    uint64 `json:"dispute"`
	Round      int64  `json:"round"`
	Seq        uint64 `json:"seq"`
	Voter      string `json:"voter"`
	Choice     string `json:"choice"`
	Salt       string `json:"salt"`
	Commitment string `json:"commitment"`
	At         string `json:"at"`
	Revealed   string `json:"revealed,omitempty"`
}

func votesDir() (string, error) {
	if d := os.Getenv("GNORACLE_HOME"); d != "" {
		return filepath.Join(d, "votes"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".gnoracle", "votes"), nil
}

func (c *cli) commit(a []string) error {
	if err := need(a, 2, "commit <dispute> <UPHOLD|OVERTURN|OVERTURN_MINOR|VOID|ABSTAIN>"); err != nil {
		return err
	}
	dispute, err := strconv.ParseUint(a[0], 10, 64)
	if err != nil {
		return err
	}
	choice := strings.ToUpper(a[1])
	if !gnochain.ValidChoice(choice) {
		return fmt.Errorf("choice must be one of UPHOLD, OVERTURN, OVERTURN_MINOR, VOID, ABSTAIN")
	}
	if err := c.connect(true); err != nil {
		return err
	}
	bl, err := c.client.BallotOfDispute(c.dao, dispute)
	if err != nil {
		return err
	}
	if bl == nil {
		return fmt.Errorf("dispute %d has no ballot", dispute)
	}
	if phase := bl.LivePhase(bl.Now); phase != "commit" {
		return fmt.Errorf("ballot for dispute %d is in the %s phase (commit ended at %d)", dispute, phase, bl.CommitEnds)
	}
	dir, err := votesDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(dir, fmt.Sprintf("%s-%d-%d.json", c.chain, dispute, bl.Round))
	var rec voteRecord
	if b, err := os.ReadFile(path); err == nil && json.Unmarshal(b, &rec) == nil && rec.Salt != "" && rec.Choice == choice {
		// the same choice again: the same commitment (the realm overwrites in place)
		fmt.Println("re-using the saved salt from", path)
		fmt.Printf("commitment %s\nsalt kept in %s — keep this file until you reveal (reveal opens at %d, closes at %d)\n", rec.Commitment, path, bl.CommitEnds, bl.RevealEnds)
		return c.tx(c.dao, "CommitVote", strconv.FormatUint(dispute, 10), rec.Commitment)
	}
	// a first commitment, or a changed choice: a fresh salt. The new record is
	// written beside the old one and replaces it only once the transaction
	// committed, so a failed change never loses the salt that is on chain.
	salt, err := gnochain.NewSalt()
	if err != nil {
		return err
	}
	rec = voteRecord{Chain: c.chain, Dispute: dispute, Round: bl.Round, Seq: bl.Seq, Voter: c.client.Bech32(), Choice: choice, Salt: salt, At: time.Now().UTC().Format(time.RFC3339)}
	rec.Commitment = gnochain.Commitment(dispute, int(bl.Round), choice, salt, rec.Voter)
	b, _ := json.MarshalIndent(rec, "", "  ")
	pending := path + ".pending"
	if err := os.WriteFile(pending, b, 0o600); err != nil {
		return err
	}
	fmt.Printf("commitment %s\nsalt kept in %s — keep this file until you reveal (reveal opens at %d, closes at %d)\n", rec.Commitment, path, bl.CommitEnds, bl.RevealEnds)
	if err := c.tx(c.dao, "CommitVote", strconv.FormatUint(dispute, 10), rec.Commitment); err != nil {
		_ = os.Remove(pending)
		return err
	}
	return os.Rename(pending, path)
}

func (c *cli) reveal(a []string) error {
	if err := need(a, 1, "reveal <dispute>"); err != nil {
		return err
	}
	dispute, err := strconv.ParseUint(a[0], 10, 64)
	if err != nil {
		return err
	}
	if err := c.connect(true); err != nil {
		return err
	}
	bl, err := c.client.BallotOfDispute(c.dao, dispute)
	if err != nil {
		return err
	}
	if bl == nil {
		return fmt.Errorf("dispute %d has no ballot", dispute)
	}
	dir, err := votesDir()
	if err != nil {
		return err
	}
	path := filepath.Join(dir, fmt.Sprintf("%s-%d-%d.json", c.chain, dispute, bl.Round))
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("no saved commitment for dispute %d round %d (%s)", dispute, bl.Round, path)
	}
	var rec voteRecord
	if err := json.Unmarshal(b, &rec); err != nil {
		return err
	}
	if rec.Voter != c.client.Bech32() {
		return fmt.Errorf("the saved commitment was made by %s, not %s", rec.Voter, c.client.Bech32())
	}
	if phase := bl.LivePhase(bl.Now); phase != "reveal" {
		return fmt.Errorf("ballot for dispute %d is in the %s phase (reveal runs %d to %d)", dispute, phase, bl.CommitEnds, bl.RevealEnds)
	}
	if err := c.tx(c.dao, "RevealVote", strconv.FormatUint(dispute, 10), rec.Choice, rec.Salt); err != nil {
		return err
	}
	rec.Revealed = time.Now().UTC().Format(time.RFC3339)
	out, _ := json.MarshalIndent(rec, "", "  ")
	_ = os.WriteFile(path, out, 0o600)
	return nil
}

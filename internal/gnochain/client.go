// Package gnochain is the thin chain layer the Gnoracle tools share: a signing
// client over gnoclient for calls, raw JSON-RPC for blocks and events, typed
// readers for the realms' `:json/...` views, and the round and commitment
// arithmetic mirrored from the pure Gno packages.
package gnochain

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gnolang/gno/gno.land/pkg/gnoclient"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	rpcclient "github.com/gnolang/gno/tm2/pkg/bft/rpc/client"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/crypto/keys"
	"github.com/gnolang/gno/tm2/pkg/sdk/bank"
	"github.com/gnolang/gno/tm2/pkg/std"
)

// Config selects the chain and, optionally, the signing key.
type Config struct {
	Remote  string // RPC URL, e.g. http://127.0.0.1:26657 or https://rpc.gno.land:443
	ChainID string // dev, pearl-1, gnoland-1

	// Signing. Leave KeyName empty for a read-only client. The password comes
	// from Password, then PasswordFile, then $GNORACLE_KEY_PASSWORD. Mnemonic
	// (or $GNORACLE_MNEMONIC) builds an in-memory keybase instead of KeyHome.
	KeyHome      string
	KeyName      string
	Password     string
	PasswordFile string
	Mnemonic     string

	Gas     GasConfig
	Timeout time.Duration
}

// GasConfig prices transactions. gno.land charges the whole fee whatever the
// gas used, so "estimate" simulates first and asks for the measured gas plus
// a margin; "fixed" always asks for Wanted.
type GasConfig struct {
	Mode       string // estimate (default) | fixed
	Wanted     int64  // fixed gas, and the ceiling in estimate mode
	Price      string // ugnot per gas, e.g. "0.001ugnot" (gnoland-1 minimum)
	MarginBps  int64  // estimate mode: added to the simulated gas (default 2500 = 25%)
	MaxDeposit string // storage deposit ceiling per call, e.g. "5000000ugnot"
}

// Defaults fills unset gas fields.
func (g *GasConfig) Defaults() {
	if g.Mode == "" {
		g.Mode = "estimate"
	}
	if g.Wanted <= 0 {
		g.Wanted = 60_000_000
	}
	if g.Price == "" {
		g.Price = "0.001ugnot"
	}
	if g.MarginBps <= 0 {
		g.MarginBps = 2500
	}
	if g.MaxDeposit == "" {
		g.MaxDeposit = "5000000ugnot"
	}
}

// Client talks to one chain, signing as one key when configured.
type Client struct {
	mu     sync.Mutex // one transaction at a time per key: sequences are read from the chain
	cfg    Config
	rpc    *rpcclient.RPCClient
	gc     *gnoclient.Client
	info   keys.Info
	price  float64
	denom  string
	maxDep std.Coins
	raw    *rawRPC
}

// New connects (lazily: the first query reaches the node) and opens the key.
func New(cfg Config) (*Client, error) {
	if cfg.Remote == "" {
		return nil, errors.New("gnochain: remote is required")
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 30 * time.Second
	}
	cfg.Gas.Defaults()
	rpc, err := rpcclient.NewHTTPClient(cfg.Remote, rpcclient.WithRequestTimeout(cfg.Timeout))
	if err != nil {
		return nil, fmt.Errorf("gnochain: rpc client: %w", err)
	}
	price, denom, err := parseGasPrice(cfg.Gas.Price)
	if err != nil {
		return nil, err
	}
	maxDep, err := std.ParseCoins(cfg.Gas.MaxDeposit)
	if err != nil {
		return nil, fmt.Errorf("gnochain: max deposit %q: %w", cfg.Gas.MaxDeposit, err)
	}
	c := &Client{cfg: cfg, rpc: rpc, gc: &gnoclient.Client{RPCClient: rpc}, price: price, denom: denom, maxDep: maxDep, raw: newRawRPC(cfg.Remote, cfg.Timeout)}
	if cfg.KeyName != "" || cfg.Mnemonic != "" || os.Getenv("GNORACLE_MNEMONIC") != "" {
		if err := c.openKey(); err != nil {
			return nil, err
		}
	}
	return c, nil
}

// Config returns the configuration in use (with defaults applied).
func (c *Client) Config() Config { return c.cfg }

// CanSign reports whether a key is loaded.
func (c *Client) CanSign() bool { return c.info != nil }

// Address is the signing address, or the zero address for a read-only client.
func (c *Client) Address() crypto.Address {
	if c.info == nil {
		return crypto.Address{}
	}
	return c.info.GetAddress()
}

// Bech32 is the signing address as text, or "" when read-only.
func (c *Client) Bech32() string {
	if c.info == nil {
		return ""
	}
	return c.info.GetAddress().String()
}

// Render calls Render(path) on a realm and returns the text.
func (c *Client) Render(pkgPath, path string) (string, error) {
	out, _, err := c.gc.Render(pkgPath, path)
	if err != nil {
		return "", fmt.Errorf("render %s:%s: %w", pkgPath, path, err)
	}
	return out, nil
}

// QEval evaluates an expression on a realm and returns the raw typed result,
// e.g. "(42 int64)".
func (c *Client) QEval(pkgPath, expr string) (string, error) {
	out, _, err := c.gc.QEval(pkgPath, expr)
	if err != nil {
		return "", fmt.Errorf("qeval %s.%s: %w", pkgPath, expr, err)
	}
	return out, nil
}

// Balance returns the ugnot balance of an address.
func (c *Client) Balance(addr crypto.Address) (int64, error) {
	coins, _, err := c.gc.QueryBalance(addr)
	if err != nil {
		return 0, err
	}
	return coins.AmountOf("ugnot"), nil
}

// LatestHeight is the node's latest block height.
func (c *Client) LatestHeight() (int64, error) { return c.gc.LatestBlockHeight() }

// TxResult is what a committed call returned.
type TxResult struct {
	Hash      string
	Height    int64
	GasWanted int64
	GasUsed   int64
	Fee       string
	Data      string   // raw typed results, one per line, e.g. `(5 int64)`
	Results   []string // the results decoded to plain text
}

// CallOpts tunes one call.
type CallOpts struct {
	Send     string // coins to send with the call, e.g. "1000000ugnot"
	Memo     string
	ExtraGas int64 // estimate mode: headroom added to the simulated gas before the margin, for calls whose cost can grow between simulation and inclusion (a Submit that ends up finalising the round)
}

// Call signs and broadcasts one MsgCall and waits for it to commit. Args are
// the realm function's parameters as decimal or plain strings (MsgCall
// carries primitives only). A realm panic surfaces as an error carrying the
// realm's message.
func (c *Client) Call(ctx context.Context, pkgPath, fn string, opts CallOpts, args ...string) (*TxResult, error) {
	if !c.CanSign() {
		return nil, errors.New("gnochain: no signing key configured")
	}
	var send std.Coins
	if opts.Send != "" {
		var err error
		if send, err = std.ParseCoins(opts.Send); err != nil {
			return nil, fmt.Errorf("gnochain: send %q: %w", opts.Send, err)
		}
	}
	if args == nil {
		args = []string{}
	}
	msg := vm.MsgCall{Caller: c.Address(), Send: send, MaxDeposit: c.maxDep, PkgPath: pkgPath, Func: fn, Args: args}
	return c.broadcast(ctx, opts.Memo, opts.ExtraGas, func(cfg gnoclient.BaseTxCfg) (*std.Tx, error) { return gnoclient.NewCallTx(cfg, msg) })
}

// SendCoins signs and broadcasts a bank send (the agent's dev-mode tick).
func (c *Client) SendCoins(ctx context.Context, to crypto.Address, amount string) (*TxResult, error) {
	if !c.CanSign() {
		return nil, errors.New("gnochain: no signing key configured")
	}
	coins, err := std.ParseCoins(amount)
	if err != nil {
		return nil, err
	}
	msg := bank.MsgSend{FromAddress: c.Address(), ToAddress: to, Amount: coins}
	return c.broadcast(ctx, "", 0, func(cfg gnoclient.BaseTxCfg) (*std.Tx, error) { return gnoclient.NewSendTx(cfg, msg) })
}

func (c *Client) broadcast(ctx context.Context, memo string, extraGas int64, build func(gnoclient.BaseTxCfg) (*std.Tx, error)) (*TxResult, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	acc, _, err := c.gc.QueryAccount(c.Address())
	if err != nil {
		return nil, fmt.Errorf("gnochain: query account %s: %w", c.Bech32(), err)
	}
	gasWanted := c.cfg.Gas.Wanted
	cfg := gnoclient.BaseTxCfg{GasWanted: gasWanted, GasFee: c.fee(gasWanted), AccountNumber: acc.AccountNumber, SequenceNumber: acc.Sequence, Memo: memo}
	tx, err := build(cfg)
	if err != nil {
		return nil, err
	}
	if c.cfg.Gas.Mode == "estimate" {
		sim := *tx
		sim.Signatures = []std.Signature{{PubKey: c.info.GetPubKey(), Signature: nil}}
		used, err := c.gc.EstimateGas(&sim)
		if err != nil {
			return nil, fmt.Errorf("simulate: %w", err)
		}
		// the caller's headroom covers work the simulation did not see; the
		// margin covers the ordinary variance on top of it
		used += extraGas
		gasWanted = used + used*c.cfg.Gas.MarginBps/10_000
		if gasWanted > c.cfg.Gas.Wanted {
			gasWanted = c.cfg.Gas.Wanted
		}
		fee, err := std.ParseCoin(c.fee(gasWanted))
		if err != nil {
			return nil, err
		}
		tx.Fee = std.NewFee(gasWanted, fee)
	}
	signed, err := c.gc.SignTx(*tx, acc.AccountNumber, acc.Sequence)
	if err != nil {
		return nil, fmt.Errorf("sign: %w", err)
	}
	res, err := c.gc.BroadcastTxCommit(signed)
	if err != nil {
		if strings.Contains(err.Error(), "signature verification failed") {
			return nil, fmt.Errorf("sequence mismatch: another transaction from this key was included first; retry: %w", err)
		}
		return nil, fmt.Errorf("broadcast: %w", err)
	}
	if res.CheckTx.Error != nil {
		return nil, fmt.Errorf("checktx: %s: %s", res.CheckTx.Error.Error(), trimLog(res.CheckTx.Log))
	}
	if res.DeliverTx.Error != nil {
		return nil, fmt.Errorf("delivertx: %s: %s", res.DeliverTx.Error.Error(), trimLog(res.DeliverTx.Log))
	}
	data := string(res.DeliverTx.Data)
	return &TxResult{
		Hash:      fmt.Sprintf("%X", res.Hash),
		Height:    res.Height,
		GasWanted: res.DeliverTx.GasWanted,
		GasUsed:   res.DeliverTx.GasUsed,
		Fee:       tx.Fee.GasFee.String(),
		Data:      data,
		Results:   DecodeResults(data),
	}, nil
}

// fee prices gasWanted at the configured gas price, rounded up.
func (c *Client) fee(gasWanted int64) string {
	amt := int64(math.Ceil(float64(gasWanted) * c.price))
	if amt < 1 {
		amt = 1
	}
	return strconv.FormatInt(amt, 10) + c.denom
}

// parseGasPrice splits "0.001ugnot" into 0.001 and "ugnot".
func parseGasPrice(s string) (float64, string, error) {
	s = strings.TrimSpace(s)
	i := 0
	for i < len(s) && (s[i] >= '0' && s[i] <= '9' || s[i] == '.') {
		i++
	}
	if i == 0 || i == len(s) {
		return 0, "", fmt.Errorf("gnochain: gas price %q must look like 0.001ugnot", s)
	}
	f, err := strconv.ParseFloat(s[:i], 64)
	if err != nil || f <= 0 {
		return 0, "", fmt.Errorf("gnochain: gas price %q: bad number", s)
	}
	return f, s[i:], nil
}

// trimLog keeps the realm's own message out of a multi-kilobyte VM trace.
func trimLog(log string) string {
	log = strings.TrimSpace(log)
	if i := strings.Index(log, "Stack Trace:"); i > 0 {
		log = strings.TrimSpace(log[:i])
	}
	if i := strings.Index(log, "Machine State"); i > 0 {
		log = strings.TrimSpace(log[:i])
	}
	if len(log) > 600 {
		log = log[:600] + "…"
	}
	return log
}

// openKey loads the signing key from a mnemonic or a keybase directory.
func (c *Client) openKey() error {
	cfg := &c.cfg
	if cfg.Password == "" && cfg.PasswordFile != "" {
		b, err := os.ReadFile(cfg.PasswordFile)
		if err != nil {
			return fmt.Errorf("gnochain: password file: %w", err)
		}
		cfg.Password = strings.TrimRight(string(b), "\r\n")
	}
	if cfg.Password == "" {
		cfg.Password = os.Getenv("GNORACLE_KEY_PASSWORD")
	}
	mnemonic := cfg.Mnemonic
	if mnemonic == "" {
		mnemonic = os.Getenv("GNORACLE_MNEMONIC")
	}
	var kb keys.Keybase
	name := cfg.KeyName
	if mnemonic != "" {
		kb = keys.NewInMemory()
		if name == "" {
			name = "gnoracle"
		}
		if cfg.Password == "" {
			cfg.Password = "in-memory"
		}
		if _, err := kb.CreateAccount(name, strings.TrimSpace(mnemonic), "", cfg.Password, 0, 0); err != nil {
			return fmt.Errorf("gnochain: mnemonic: %w", err)
		}
	} else {
		if cfg.KeyHome == "" {
			return errors.New("gnochain: key_home is required when key is set")
		}
		// The on-disk keybase takes an exclusive lock, so copy the key into
		// memory and release it: the agent, the bot and gnokey can then share
		// one keybase directory.
		// The database opens lazily on first use, so the lock retry wraps the
		// first lookup, not the constructor.
		var disk keys.Keybase
		var info keys.Info
		var err error
		for attempt := 0; ; attempt++ {
			if disk, err = keys.NewKeyBaseFromDir(cfg.KeyHome); err == nil {
				if info, err = disk.GetByNameOrAddress(name); err == nil {
					break
				}
				disk.CloseDB()
			}
			if !strings.Contains(err.Error(), "resource temporarily unavailable") && !strings.Contains(err.Error(), "initializing DB") {
				return fmt.Errorf("gnochain: key %q in %s: %w", name, cfg.KeyHome, err)
			}
			if attempt >= 40 {
				return fmt.Errorf("gnochain: keybase %s: %w (another process is holding it)", cfg.KeyHome, err)
			}
			time.Sleep(250 * time.Millisecond)
		}
		if cfg.Password == "" {
			cfg.Password = "in-memory"
		}
		priv, err := disk.ExportPrivKey(info.GetName(), cfg.Password)
		disk.CloseDB()
		if err != nil {
			return fmt.Errorf("gnochain: key %q: %w (set GNORACLE_KEY_PASSWORD or password_file)", name, err)
		}
		name = info.GetName()
		kb = keys.NewInMemory()
		if err := kb.ImportPrivKey(name, priv, cfg.Password); err != nil {
			return fmt.Errorf("gnochain: key %q: %w", name, err)
		}
	}
	info, err := kb.GetByNameOrAddress(name)
	if err != nil {
		return fmt.Errorf("gnochain: key %q: %w", name, err)
	}
	c.info = info
	c.gc.Signer = gnoclient.SignerFromKeybase{Keybase: kb, Account: name, Password: cfg.Password, ChainID: cfg.ChainID}
	// Fail now, not at the first transaction, if the password is wrong.
	if _, _, err := kb.Sign(name, cfg.Password, []byte("gnoracle")); err != nil {
		return fmt.Errorf("gnochain: key %q: %w (set GNORACLE_KEY_PASSWORD or password_file)", name, err)
	}
	return nil
}

// ParseAddress parses a bech32 address.
func ParseAddress(s string) (crypto.Address, error) {
	a, err := crypto.AddressFromBech32(strings.TrimSpace(s))
	if err != nil {
		return crypto.Address{}, fmt.Errorf("bad address %q: %w", s, err)
	}
	return a, nil
}

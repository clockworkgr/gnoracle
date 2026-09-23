package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/big"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

// Adapter fetches one round's samples.
type Adapter interface {
	Name() string
	Fetch(ctx context.Context) []Sample
}

// Deps is what adapters may use besides the network.
type Deps struct {
	Client *gnochain.Client
}

// NewAdapter builds the configured adapter.
func NewAdapter(s SourceConfig, deps Deps) (Adapter, error) {
	if err := s.validate(); err != nil {
		return nil, err
	}
	switch s.Adapter {
	case "http":
		a := &httpAdapter{cfg: s, http: &http.Client{Timeout: 15 * time.Second}}
		if s.Scale != "" {
			a.scale, _ = parseRat(s.Scale)
		}
		return a, nil
	case "exec":
		return &execAdapter{cfg: s}, nil
	case "file":
		return &fileAdapter{cfg: s}, nil
	case "gnoswap":
		if deps.Client == nil {
			return nil, fmt.Errorf("gnoswap adapter needs a chain client")
		}
		return &gnoswapAdapter{cfg: s, client: deps.Client}, nil
	case "qeval":
		if deps.Client == nil {
			return nil, fmt.Errorf("qeval adapter needs a chain client")
		}
		return &qevalAdapter{cfg: s, client: deps.Client}, nil
	}
	return nil, fmt.Errorf("unknown adapter %q", s.Adapter)
}

const rawLimit = 800

func clip(b []byte) string {
	if len(b) > rawLimit {
		return string(b[:rawLimit]) + "…"
	}
	return string(b)
}

// ---- http

type httpAdapter struct {
	cfg   SourceConfig
	http  *http.Client
	scale *big.Rat
}

func (a *httpAdapter) Name() string { return "http" }

// MinSources is the configured floor, else all of one URL or a majority.
func (a *httpAdapter) MinSources() int {
	if a.cfg.MinSources > 0 {
		return a.cfg.MinSources
	}
	return len(a.cfg.URLs)/2 + 1
}

func (a *httpAdapter) Fetch(ctx context.Context) []Sample {
	out := make([]Sample, len(a.cfg.URLs))
	var wg sync.WaitGroup
	for i, u := range a.cfg.URLs {
		wg.Add(1)
		go func(i int, u string) {
			defer wg.Done()
			out[i] = a.one(ctx, u)
		}(i, u)
	}
	wg.Wait()
	return out
}

func (a *httpAdapter) one(ctx context.Context, u string) Sample {
	s := Sample{Source: redactURL(u)} // the journal must not keep API keys from query strings
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		s.Err = err.Error()
		return s
	}
	req.Header.Set("User-Agent", "gnoracle-agent/1.0")
	req.Header.Set("Accept", "application/json")
	for k, v := range a.cfg.Headers {
		req.Header.Set(k, os.ExpandEnv(v))
	}
	resp, err := a.http.Do(req)
	if err != nil {
		s.Err = err.Error()
		return s
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		s.Err = err.Error()
		return s
	}
	s.Raw = clip(body)
	if resp.StatusCode/100 != 2 {
		s.Err = "http " + resp.Status
		return s
	}
	leaf, err := ExtractJSONPath(body, a.cfg.Path)
	if err != nil {
		s.Err = err.Error()
		return s
	}
	ParseNumberOrLabel(&s, leaf)
	if s.Num != nil && a.scale != nil {
		s.Num = new(big.Rat).Mul(s.Num, a.scale)
		s.finish()
	}
	return s
}

// ExtractJSONPath walks a dotted path with [n] indexes through a JSON body
// and returns the leaf as text. Numbers keep their exact decimal form.
func ExtractJSONPath(body []byte, path string) (string, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return "", fmt.Errorf("body is not JSON: %w", err)
	}
	for _, step := range splitPath(path) {
		switch cur := v.(type) {
		case map[string]any:
			next, ok := cur[step]
			if !ok {
				return "", fmt.Errorf("path %q: no key %q", path, step)
			}
			v = next
		case []any:
			idx, err := strconv.Atoi(step)
			if err != nil || idx < 0 || idx >= len(cur) {
				return "", fmt.Errorf("path %q: bad index %q", path, step)
			}
			v = cur[idx]
		default:
			return "", fmt.Errorf("path %q: cannot descend into %T at %q", path, v, step)
		}
	}
	switch leaf := v.(type) {
	case json.Number:
		return leaf.String(), nil
	case string:
		return leaf, nil
	case bool:
		return strconv.FormatBool(leaf), nil
	case nil:
		return "", fmt.Errorf("path %q: null", path)
	}
	return "", fmt.Errorf("path %q: leaf is %T, not a scalar", path, v)
}

// splitPath turns "data[0].price" into ["data", "0", "price"].
func splitPath(path string) []string {
	var out []string
	for _, part := range strings.Split(strings.TrimSpace(path), ".") {
		for part != "" {
			i := strings.IndexByte(part, '[')
			if i < 0 {
				out = append(out, part)
				break
			}
			if i > 0 {
				out = append(out, part[:i])
			}
			j := strings.IndexByte(part, ']')
			if j < i {
				out = append(out, part[i+1:])
				break
			}
			out = append(out, part[i+1:j])
			part = part[j+1:]
		}
	}
	return out
}

// ---- exec

type execAdapter struct{ cfg SourceConfig }

func (a *execAdapter) Name() string { return "exec" }

func (a *execAdapter) Fetch(ctx context.Context) []Sample {
	s := Sample{Source: strings.Join(a.cfg.Command, " ")}
	cmd := exec.CommandContext(ctx, a.cfg.Command[0], a.cfg.Command[1:]...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	s.Raw = clip(append(stdout.Bytes(), stderr.Bytes()...))
	if err != nil {
		s.Err = err.Error()
		return []Sample{s}
	}
	text := strings.TrimSpace(stdout.String())
	if text == "" {
		s.Err = "command printed nothing"
		return []Sample{s}
	}
	ParseNumberOrLabel(&s, text)
	return []Sample{s}
}

// ---- file

type fileAdapter struct{ cfg SourceConfig }

func (a *fileAdapter) Name() string { return "file" }

func (a *fileAdapter) Fetch(context.Context) []Sample {
	s := Sample{Source: a.cfg.File}
	b, err := os.ReadFile(a.cfg.File)
	if err != nil {
		s.Err = "no answer yet: " + err.Error()
		return []Sample{s}
	}
	text := strings.TrimSpace(string(b))
	s.Raw = clip(b)
	if text == "" {
		s.Err = "no answer yet: file is empty"
		return []Sample{s}
	}
	ParseNumberOrLabel(&s, text)
	return []Sample{s}
}

// ---- gnoswap

type gnoswapAdapter struct {
	cfg    SourceConfig
	client *gnochain.Client
}

func (a *gnoswapAdapter) Name() string { return "gnoswap" }

// Fetch reads the pool's arithmetic-mean tick over seconds_ago through
// OracleConsult and converts it to a price: 1.0001^tick scaled by the
// tokens' decimals gives token1 per token0; invert flips it.
func (a *gnoswapAdapter) Fetch(context.Context) []Sample {
	pkg := a.cfg.PkgPath
	if pkg == "" {
		pkg = "gno.land/r/gnoswap/pool"
	}
	secs := a.cfg.SecondsAgo
	if secs == 0 {
		secs = 1800
	}
	expr := fmt.Sprintf("OracleConsult(%q, %d)", a.cfg.Pool, secs)
	s := Sample{Source: pkg + "." + expr}
	out, err := a.client.QEval(pkg, expr)
	if err != nil {
		s.Err = err.Error()
		return []Sample{s}
	}
	s.Raw = clip([]byte(out))
	res := gnochain.DecodeResults(out)
	if len(res) >= 3 && res[2] != "nil" && res[2] != "undefined" && !strings.HasPrefix(res[2], "nil ") {
		s.Err = "OracleConsult returned an error: " + res[2]
		return []Sample{s}
	}
	if len(res) == 0 {
		s.Err = "no result"
		return []Sample{s}
	}
	tick, err := strconv.ParseInt(res[0], 10, 64)
	if err != nil {
		s.Err = "tick: " + err.Error()
		return []Sample{s}
	}
	s.Num = TickToPrice(tick, a.cfg.Decimals0, a.cfg.Decimals1, a.cfg.Invert)
	s.finish()
	return []Sample{s}
}

// TickToPrice converts a Uniswap-v3 style tick to a human price.
func TickToPrice(tick int64, dec0, dec1 int, invert bool) *big.Rat {
	raw := math.Pow(1.0001, float64(tick)) // token1 raw units per token0 raw unit
	price := new(big.Rat).SetFloat64(raw)
	if price == nil {
		return big.NewRat(0, 1)
	}
	// human = raw × 10^dec0 / 10^dec1
	price.Mul(price, new(big.Rat).SetInt(pow10(dec0)))
	price.Quo(price, new(big.Rat).SetInt(pow10(dec1)))
	if invert && price.Sign() != 0 {
		price.Inv(price)
	}
	return price
}

// ---- qeval

type qevalAdapter struct {
	cfg    SourceConfig
	client *gnochain.Client
}

func (a *qevalAdapter) Name() string { return "qeval" }

func (a *qevalAdapter) Fetch(context.Context) []Sample {
	s := Sample{Source: a.cfg.PkgPath + "." + a.cfg.Expr}
	out, err := a.client.QEval(a.cfg.PkgPath, a.cfg.Expr)
	if err != nil {
		s.Err = err.Error()
		return []Sample{s}
	}
	s.Raw = clip([]byte(out))
	res := gnochain.DecodeResults(out)
	if len(res) == 0 {
		s.Err = "no result"
		return []Sample{s}
	}
	n, ok := new(big.Rat).SetString(res[0])
	if !ok {
		s.Label = res[0]
		s.finish()
		return []Sample{s}
	}
	if a.cfg.ResultDecimals > 0 {
		n.Quo(n, new(big.Rat).SetInt(pow10(a.cfg.ResultDecimals)))
	}
	s.Num = n
	s.finish()
	return []Sample{s}
}

// redactURL drops the query string and user info from a URL for logs.
func redactURL(raw string) string {
	if i := strings.IndexByte(raw, '?'); i >= 0 {
		raw = raw[:i] + "?…"
	}
	if at := strings.IndexByte(raw, '@'); at >= 0 {
		if scheme := strings.Index(raw, "://"); scheme >= 0 && at > scheme {
			raw = raw[:scheme+3] + "…@" + raw[at+1:]
		}
	}
	return raw
}

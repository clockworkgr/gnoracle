package gnochain

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// rawRPC reads blocks and events straight from the node's JSON-RPC, so the
// bot needs no indexer and no amino type registry: an emitted event arrives
// as {"@type":"/tm.Event","type":..,"attrs":[..],"pkg_path":..}.
type rawRPC struct {
	base string
	http *http.Client
}

func newRawRPC(remote string, timeout time.Duration) *rawRPC {
	return &rawRPC{base: strings.TrimRight(remote, "/"), http: &http.Client{Timeout: timeout}}
}

type rpcEnvelope struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
		Data    string `json:"data"`
	} `json:"error"`
}

func (r *rawRPC) get(ctx context.Context, method string, params url.Values, out any) error {
	u := r.base + "/" + method
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := r.http.Do(req)
	if err != nil {
		return fmt.Errorf("rpc %s: %w", method, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return err
	}
	var env rpcEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return fmt.Errorf("rpc %s: %w: %.200s", method, err, body)
	}
	if env.Error != nil {
		return fmt.Errorf("rpc %s: %s %s", method, env.Error.Message, env.Error.Data)
	}
	return json.Unmarshal(env.Result, out)
}

// Status is the node's view of the chain head.
type Status struct {
	ChainID string
	Height  int64
	Time    time.Time
}

// Status queries /status.
func (c *Client) Status(ctx context.Context) (*Status, error) {
	var res struct {
		NodeInfo struct {
			Network string `json:"network"`
		} `json:"node_info"`
		SyncInfo struct {
			Height string    `json:"latest_block_height"`
			Time   time.Time `json:"latest_block_time"`
		} `json:"sync_info"`
	}
	if err := c.raw.get(ctx, "status", nil, &res); err != nil {
		return nil, err
	}
	h, _ := strconv.ParseInt(res.SyncInfo.Height, 10, 64)
	return &Status{ChainID: res.NodeInfo.Network, Height: h, Time: res.SyncInfo.Time}, nil
}

// BlockTime returns a block's header time and transaction count.
func (c *Client) BlockTime(ctx context.Context, height int64) (time.Time, int, error) {
	var res struct {
		Block struct {
			Header struct {
				Time   time.Time `json:"time"`
				NumTxs string    `json:"num_txs"`
			} `json:"header"`
		} `json:"block"`
	}
	if err := c.raw.get(ctx, "block", url.Values{"height": {strconv.FormatInt(height, 10)}}, &res); err != nil {
		return time.Time{}, 0, err
	}
	n, _ := strconv.Atoi(res.Block.Header.NumTxs)
	return res.Block.Header.Time, n, nil
}

// Event is one realm event as committed in a block.
type Event struct {
	Height  int64
	TxIndex int
	Type    string
	PkgPath string
	Attrs   map[string]string
	Order   []string // attribute keys in emission order
}

// Attr returns an attribute or "".
func (e Event) Attr(k string) string { return e.Attrs[k] }

// String renders "Type key=value ...".
func (e Event) String() string {
	var b strings.Builder
	b.WriteString(e.Type)
	for _, k := range e.Order {
		b.WriteString(" " + k + "=" + e.Attrs[k])
	}
	return b.String()
}

// BlockEvents returns the realm events of every successful transaction in a
// block, optionally limited to the given package paths.
func (c *Client) BlockEvents(ctx context.Context, height int64, pkgs map[string]bool) ([]Event, error) {
	var res struct {
		Results struct {
			DeliverTx []struct {
				ResponseBase struct {
					Error  json.RawMessage   `json:"Error"`
					Events []json.RawMessage `json:"Events"`
				} `json:"ResponseBase"`
			} `json:"deliver_tx"`
		} `json:"results"`
	}
	if err := c.raw.get(ctx, "block_results", url.Values{"height": {strconv.FormatInt(height, 10)}}, &res); err != nil {
		return nil, err
	}
	var out []Event
	for i, tx := range res.Results.DeliverTx {
		if len(tx.ResponseBase.Error) > 0 && string(tx.ResponseBase.Error) != "null" {
			continue // a failed transaction's events were rolled back
		}
		for _, raw := range tx.ResponseBase.Events {
			var ev struct {
				Kind    string `json:"@type"`
				Type    string `json:"type"`
				PkgPath string `json:"pkg_path"`
				Attrs   []struct {
					Key   string `json:"key"`
					Value string `json:"value"`
				} `json:"attrs"`
			}
			if err := json.Unmarshal(raw, &ev); err != nil || ev.Kind != "/tm.Event" {
				continue
			}
			if pkgs != nil && !pkgs[ev.PkgPath] {
				continue
			}
			e := Event{Height: height, TxIndex: i, Type: ev.Type, PkgPath: ev.PkgPath, Attrs: map[string]string{}}
			for _, a := range ev.Attrs {
				e.Attrs[a.Key] = a.Value
				e.Order = append(e.Order, a.Key)
			}
			out = append(out, e)
		}
	}
	return out, nil
}

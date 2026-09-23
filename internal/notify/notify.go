// Package notify delivers the tools' messages: Telegram through the Bot API
// over plain HTTPS, or the log when no token is configured.
package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Notifier sends one text to one chat.
type Notifier interface {
	Send(ctx context.Context, chatID int64, text string) error
}

// Telegram posts through api.telegram.org.
type Telegram struct {
	Token string
	HTTP  *http.Client
	Base  string // override for tests
}

// NewTelegram builds a Bot API client.
func NewTelegram(token string) *Telegram {
	return &Telegram{Token: token, HTTP: &http.Client{Timeout: 15 * time.Second}}
}

// Send posts a plain-text message (no parse mode, so realm text cannot
// break the markup).
func (t *Telegram) Send(ctx context.Context, chatID int64, text string) error {
	if chatID == 0 {
		return nil
	}
	if len(text) > 4000 {
		text = text[:4000] + "…"
	}
	base := t.Base
	if base == "" {
		base = "https://api.telegram.org"
	}
	body, _ := json.Marshal(map[string]any{"chat_id": chatID, "text": text, "disable_web_page_preview": true})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/bot"+t.Token+"/sendMessage", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := t.HTTP.Do(req)
	if err != nil {
		// a transport error quotes the URL, which carries the token
		return errors.New("telegram: " + strings.ReplaceAll(err.Error(), t.Token, "***"))
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2000))
		return fmt.Errorf("telegram: %s: %s", resp.Status, strings.ReplaceAll(string(b), t.Token, "***"))
	}
	return nil
}

// Log writes messages to the standard logger.
type Log struct{}

// Send logs the message.
func (Log) Send(_ context.Context, chatID int64, text string) error {
	log.Printf("notify[%s]: %s", strconv.FormatInt(chatID, 10), text)
	return nil
}

// Multi fans out to several notifiers; the first error is returned after all
// have been tried.
type Multi []Notifier

// Send delivers through every notifier.
func (m Multi) Send(ctx context.Context, chatID int64, text string) error {
	var first error
	for _, n := range m {
		if err := n.Send(ctx, chatID, text); err != nil && first == nil {
			first = err
		}
	}
	return first
}

// New picks Telegram when a token is set, the log otherwise; with echo the
// log is added alongside Telegram.
func New(token string, echo bool) Notifier {
	if token == "" {
		return Log{}
	}
	if echo {
		return Multi{NewTelegram(token), Log{}}
	}
	return NewTelegram(token)
}

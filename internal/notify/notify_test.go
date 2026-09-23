package notify

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestTelegramSend(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/botTOKEN/sendMessage" {
			t.Errorf("path %s", r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()
	tg := NewTelegram("TOKEN")
	tg.Base = srv.URL
	if err := tg.Send(context.Background(), 42, "hello"); err != nil {
		t.Fatal(err)
	}
	if got["text"] != "hello" || got["chat_id"].(float64) != 42 {
		t.Fatalf("payload %v", got)
	}
	if err := tg.Send(context.Background(), 0, "skipped"); err != nil {
		t.Fatal("chat 0 must be a no-op")
	}
}

func TestNew(t *testing.T) {
	if _, ok := New("", false).(Log); !ok {
		t.Fatal("log without token")
	}
	if _, ok := New("x", true).(Multi); !ok {
		t.Fatal("multi with echo")
	}
}

package spec

import "testing"

func TestDuplicateKeyScanner(t *testing.T) {
	if got, _ := duplicateKey(`{"a":{"a":1},"b":["a","a"],"c":"a"}`); got != "" {
		t.Fatalf("nested keys and strings are not top-level duplicates: %q", got)
	}
	if got, _ := duplicateKey(`{"a":1,"b":"x\\"a\\":","a":2}`); got != "a" {
		t.Fatalf("want a, got %q", got)
	}
	if got, _ := duplicateKey(`{"kind":"recurring","name":"n","kind":"oneoff"}`); got != "kind" {
		t.Fatalf("want kind, got %q", got)
	}
	// escapes in values are fine; escapes in keys are reported. Interpreted
	// strings keep the backslashes intact through gno fmt.
	if dup, esc := duplicateKey("{\"a\":\"x\\\"y\",\"b\":\"\\u0041\"}"); dup != "" || esc {
		t.Fatalf("escaped values must pass: %q %v", dup, esc)
	}
	if _, esc := duplicateKey("{\"name\":\"a\",\"\\u006eame\":\"b\"}"); !esc {
		t.Fatal("an escaped key must be reported")
	}
}

func TestEscapedKeyRefused(t *testing.T) {
	text := "{\"name\":\"Honest\",\"\\u006eame\":\"Other\",\"kind\":\"recurring\"}"
	_, err := Parse(text, 0, Limits{})
	if err == nil || err.Error() != "spec: escaped characters are not allowed in field names" {
		t.Fatalf("want the escaped-key error, got %v", err)
	}
}

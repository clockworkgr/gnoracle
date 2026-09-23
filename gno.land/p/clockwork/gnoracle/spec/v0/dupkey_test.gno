package spec

import "testing"

func TestDuplicateKeyScanner(t *testing.T) {
	if got := duplicateKey(`{"a":{"a":1},"b":["a","a"],"c":"a"}`); got != "" {
		t.Fatalf("nested keys and strings are not top-level duplicates: %q", got)
	}
	if got := duplicateKey(`{"a":1,"b":"x\\"a\\":","a":2}`); got != "a" {
		t.Fatalf("want a, got %q", got)
	}
	if got := duplicateKey(`{"kind":"recurring","name":"n","kind":"oneoff"}`); got != "kind" {
		t.Fatalf("want kind, got %q", got)
	}
}

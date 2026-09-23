package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

// FeedState is what the agent remembers about one feed between ticks and
// restarts, so a restart never double-submits or forgets its own last value.
type FeedState struct {
	StartAt     int64  `json:"startAt"` // the schedule the rounds below belong to; a change resets them
	HasRound    bool   `json:"hasRound"`
	LastRound   uint64 `json:"lastRound"`
	HasValue    bool   `json:"hasValue"`
	LastValue   int64  `json:"lastValue"`
	LastClaimAt int64  `json:"lastClaimAt"`
	LastTxHash  string `json:"lastTxHash"`
}

// State is the on-disk agent state.
type State struct {
	mu    sync.Mutex
	path  string
	Chain string                `json:"chain"` // chain id the state belongs to
	Feeds map[string]*FeedState `json:"feeds"`
}

// LoadState reads the state file, or starts empty.
func LoadState(path string) (*State, error) {
	s := &State{path: path, Feeds: map[string]*FeedState{}}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, s); err != nil {
		return nil, err
	}
	if s.Feeds == nil {
		s.Feeds = map[string]*FeedState{}
	}
	return s, nil
}

// Feed returns the mutable state of one feed.
func (s *State) Feed(id uint64) *FeedState {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := strconv.FormatUint(id, 10)
	if s.Feeds[k] == nil {
		s.Feeds[k] = &FeedState{}
	}
	return s.Feeds[k]
}

// Update mutates one feed's state under the lock (runners share the file).
func (s *State) Update(id uint64, fn func(*FeedState)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := strconv.FormatUint(id, 10)
	if s.Feeds[k] == nil {
		s.Feeds[k] = &FeedState{}
	}
	fn(s.Feeds[k])
}

// Snapshot returns a copy of one feed's state.
func (s *State) Snapshot(id uint64) FeedState {
	s.mu.Lock()
	defer s.mu.Unlock()
	if fs := s.Feeds[strconv.FormatUint(id, 10)]; fs != nil {
		return *fs
	}
	return FeedState{}
}

// ForChain forgets everything when the chain id differs from the recorded
// one and records the current id.
func (s *State) ForChain(chainID string) (reset bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.Chain != "" && s.Chain != chainID {
		s.Feeds = map[string]*FeedState{}
		reset = true
	}
	s.Chain = chainID
	return reset
}

// Save writes the state atomically.
func (s *State) Save() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.path == "" {
		return nil
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil && filepath.Dir(s.path) != "." {
		return err
	}
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// Journal is the append-only JSONL evidence log.
type Journal struct {
	mu   sync.Mutex
	path string
}

// NewJournal opens (lazily) the journal file; an empty path disables it.
func NewJournal(path string) *Journal { return &Journal{path: path} }

// Entry is one journal line.
type Entry struct {
	At      string   `json:"at"`
	Feed    uint64   `json:"feed"`
	Round   uint64   `json:"round"`
	Kind    string   `json:"kind"` // fetch | submit | refused | finalize | claim | error | alert
	Value   *int64   `json:"value,omitempty"`
	Text    string   `json:"text,omitempty"`
	Samples []Sample `json:"samples,omitempty"`
	Tx      string   `json:"tx,omitempty"`
	GasUsed int64    `json:"gasUsed,omitempty"`
	Fee     string   `json:"fee,omitempty"`
	Err     string   `json:"err,omitempty"`
}

// Write appends one entry.
func (j *Journal) Write(e Entry) {
	if j.path == "" {
		return
	}
	e.At = time.Now().UTC().Format(time.RFC3339)
	b, err := json.Marshal(e)
	if err != nil {
		return
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	f, err := os.OpenFile(j.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.Write(append(b, '\n'))
}

package bot

import (
	"encoding/json"
	"os"
	"sync"
	"time"
)

// State survives restarts: the scan cursor and what was already sent or
// attempted, so a restart neither re-announces nor re-cranks.
type State struct {
	mu         sync.Mutex
	path       string
	Height     int64            `json:"height"`
	Sent       map[string]int64 `json:"sent"`       // reminder key -> unix time
	Attempt    map[string]int64 `json:"attempt"`    // crank key -> unix time of the last attempt
	LastRemind int64            `json:"lastRemind"` //
	LastCrank  int64            `json:"lastCrank"`
	LastKourt  int64            `json:"lastKourt"`
	LastSettle int64            `json:"lastSettle"`
}

// LoadState reads the state file or starts empty.
func LoadState(path string) (*State, error) {
	s := &State{path: path, Sent: map[string]int64{}, Attempt: map[string]int64{}}
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
	if s.Sent == nil {
		s.Sent = map[string]int64{}
	}
	if s.Attempt == nil {
		s.Attempt = map[string]int64{}
	}
	return s, nil
}

// Save writes the state atomically and prunes week-old keys.
func (s *State) Save() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := time.Now().Add(-7 * 24 * time.Hour).Unix()
	for k, t := range s.Sent {
		if t < cutoff {
			delete(s.Sent, k)
		}
	}
	for k, t := range s.Attempt {
		if t < cutoff {
			delete(s.Attempt, k)
		}
	}
	if s.path == "" {
		return nil
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// once marks key and reports whether it was new.
func (s *State) once(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.Sent[key]; ok {
		return false
	}
	s.Sent[key] = time.Now().Unix()
	return true
}

// due reports whether key was last attempted more than every ago and marks it.
func (s *State) due(key string, every time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().Unix()
	if t, ok := s.Attempt[key]; ok && now-t < int64(every/time.Second) {
		return false
	}
	s.Attempt[key] = now
	return true
}

// Package authspec parses the one-line authority descriptions the permanent
// realms accept for their two-step, timelocked authority transfers:
//
//	addr:<bech32 address>                 a single key
//	realms:<path>[,<path>...]             governance realms
//	anyof:<bech32 address>|<path>[,...]   a key or any of the realms
//
// Keeping the description a string lets a pending transfer be stored,
// emitted and read back exactly as it was proposed.
package authspec

import (
	"errors"
	"strings"

	"gno.land/p/clockwork/upgradeable/v0"
)

// Parse builds the authority a spec describes.
func Parse(spec string) (upgradeable.Authority, error) {
	kind, rest, ok := strings.Cut(strings.TrimSpace(spec), ":")
	if !ok {
		return nil, errors.New("authspec: want addr:<address>, realms:<paths> or anyof:<address>|<paths>")
	}
	switch kind {
	case "addr":
		a, err := parseAddr(rest)
		if err != nil {
			return nil, err
		}
		return upgradeable.NewAddrAuthority(a), nil
	case "realms":
		paths, err := parsePaths(rest)
		if err != nil {
			return nil, err
		}
		return upgradeable.NewRealmAuthority(paths...), nil
	case "anyof":
		addrPart, pathPart, ok := strings.Cut(rest, "|")
		if !ok {
			return nil, errors.New("authspec: anyof wants <address>|<paths>")
		}
		a, err := parseAddr(addrPart)
		if err != nil {
			return nil, err
		}
		paths, err := parsePaths(pathPart)
		if err != nil {
			return nil, err
		}
		return upgradeable.NewAnyOf(upgradeable.NewAddrAuthority(a), upgradeable.NewRealmAuthority(paths...)), nil
	}
	return nil, errors.New("authspec: unknown kind " + kind)
}

// Kind is the spec's first word, or "".
func Kind(spec string) string {
	kind, _, ok := strings.Cut(strings.TrimSpace(spec), ":")
	if !ok {
		return ""
	}
	return kind
}

// Realms lists the realm paths a spec grants (none for addr:).
func Realms(spec string) []string {
	kind, rest, ok := strings.Cut(strings.TrimSpace(spec), ":")
	if !ok || kind == "addr" {
		return nil
	}
	if kind == "anyof" {
		if _, p, ok := strings.Cut(rest, "|"); ok {
			rest = p
		} else {
			return nil
		}
	}
	paths, err := parsePaths(rest)
	if err != nil {
		return nil
	}
	return paths
}

// Grants reports whether the spec includes the realm path.
func Grants(spec, path string) bool {
	for _, p := range Realms(spec) {
		if p == path {
			return true
		}
	}
	return false
}

func parseAddr(s string) (address, error) {
	a := address(strings.TrimSpace(s))
	if !a.IsValid() {
		return "", errors.New("authspec: invalid address " + string(a))
	}
	return a, nil
}

func parsePaths(s string) ([]string, error) {
	var paths []string
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if !strings.HasPrefix(p, "gno.land/r/") {
			return nil, errors.New("authspec: realm path must start with gno.land/r/: " + p)
		}
		paths = append(paths, p)
	}
	if len(paths) == 0 {
		return nil, errors.New("authspec: at least one realm path is required")
	}
	return paths, nil
}

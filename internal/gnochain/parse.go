package gnochain

import (
	"strconv"
	"strings"
)

// DecodeResults turns the VM's typed result lines, e.g.
//
//	(5 int64)
//	("gno.land/r/x" string)
//	(true bool)
//
// into plain strings: "5", "gno.land/r/x", "true". Composite values are
// returned as written.
func DecodeResults(data string) []string {
	var out []string
	for _, line := range strings.Split(strings.TrimSpace(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		out = append(out, DecodeResult(line))
	}
	return out
}

// DecodeResult decodes one "(value type)" line.
func DecodeResult(line string) string {
	line = strings.TrimSpace(line)
	if !strings.HasPrefix(line, "(") || !strings.HasSuffix(line, ")") {
		return line
	}
	inner := line[1 : len(line)-1]
	sp := strings.LastIndex(inner, " ")
	if sp < 0 {
		return inner
	}
	val, typ := inner[:sp], inner[sp+1:]
	switch {
	case typ == "string" || strings.HasSuffix(typ, ".address") || typ == "address":
		if s, err := strconv.Unquote(val); err == nil {
			return s
		}
		return strings.Trim(val, `"`)
	default:
		return val
	}
}

// Int64Result decodes a single numeric result.
func Int64Result(data string) (int64, bool) {
	rs := DecodeResults(data)
	if len(rs) == 0 {
		return 0, false
	}
	v, err := strconv.ParseInt(rs[0], 10, 64)
	return v, err == nil
}

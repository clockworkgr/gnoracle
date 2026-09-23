// Package jsonw writes JSON objects and arrays for the realms' machine views
// (the `:json/...` render paths the provider agent, the bot and the CLI
// read). It is a writer only: keys are appended in call order, strings are
// escaped per RFC 8259, numbers are written as decimal integers (all realm
// quantities are int64 or uint64), and nothing is validated beyond that.
package jsonw

import (
	"strconv"
	"strings"
)

// Object accumulates one JSON object.
type Object struct {
	b strings.Builder
	n int
}

// New starts an object.
func New() *Object {
	o := &Object{}
	o.b.WriteByte('{')
	return o
}

func (o *Object) key(k string) {
	if o.n > 0 {
		o.b.WriteByte(',')
	}
	o.n++
	o.b.WriteString(Quote(k))
	o.b.WriteByte(':')
}

// Str writes a string member.
func (o *Object) Str(k, v string) *Object {
	o.key(k)
	o.b.WriteString(Quote(v))
	return o
}

// Int writes an int64 member.
func (o *Object) Int(k string, v int64) *Object {
	o.key(k)
	o.b.WriteString(strconv.FormatInt(v, 10))
	return o
}

// Uint writes a uint64 member.
func (o *Object) Uint(k string, v uint64) *Object {
	o.key(k)
	o.b.WriteString(strconv.FormatUint(v, 10))
	return o
}

// Bool writes a boolean member.
func (o *Object) Bool(k string, v bool) *Object {
	o.key(k)
	if v {
		o.b.WriteString("true")
	} else {
		o.b.WriteString("false")
	}
	return o
}

// Raw writes a member whose value is already JSON.
func (o *Object) Raw(k, raw string) *Object {
	o.key(k)
	if raw == "" {
		raw = "null"
	}
	o.b.WriteString(raw)
	return o
}

// Null writes a null member.
func (o *Object) Null(k string) *Object { return o.Raw(k, "null") }

// Strs writes an array of strings.
func (o *Object) Strs(k string, vs []string) *Object {
	a := NewArray()
	for _, v := range vs {
		a.Str(v)
	}
	return o.Raw(k, a.String())
}

// Ints writes an array of int64.
func (o *Object) Ints(k string, vs []int64) *Object {
	a := NewArray()
	for _, v := range vs {
		a.Int(v)
	}
	return o.Raw(k, a.String())
}

// String closes the object. The object must not be written to afterwards.
func (o *Object) String() string { return o.b.String() + "}" }

// Array accumulates one JSON array.
type Array struct {
	b strings.Builder
	n int
}

// NewArray starts an array.
func NewArray() *Array {
	a := &Array{}
	a.b.WriteByte('[')
	return a
}

func (a *Array) sep() {
	if a.n > 0 {
		a.b.WriteByte(',')
	}
	a.n++
}

// Str appends a string element.
func (a *Array) Str(v string) *Array {
	a.sep()
	a.b.WriteString(Quote(v))
	return a
}

// Int appends an int64 element.
func (a *Array) Int(v int64) *Array {
	a.sep()
	a.b.WriteString(strconv.FormatInt(v, 10))
	return a
}

// Uint appends a uint64 element.
func (a *Array) Uint(v uint64) *Array {
	a.sep()
	a.b.WriteString(strconv.FormatUint(v, 10))
	return a
}

// Raw appends an element that is already JSON.
func (a *Array) Raw(raw string) *Array {
	a.sep()
	if raw == "" {
		raw = "null"
	}
	a.b.WriteString(raw)
	return a
}

// Len is the number of elements appended so far.
func (a *Array) Len() int { return a.n }

// String closes the array.
func (a *Array) String() string { return a.b.String() + "]" }

const hexDigits = "0123456789abcdef"

// Quote returns s as a JSON string literal.
func Quote(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				b.WriteString(`\u00`)
				b.WriteByte(hexDigits[r>>4])
				b.WriteByte(hexDigits[r&0xf])
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// Error is a one-member error object.
func Error(msg string) string { return New().Str("error", msg).String() }

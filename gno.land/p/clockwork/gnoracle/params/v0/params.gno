// Package params is a typed parameter registry with bounds and a per-change
// rate limit, the shape the plan gives every DAO-tunable number (§8.3,
// Appendix C): each parameter is defined once with its bounds, read by name,
// and changed only within its bounds and by at most MaxChangeBps of its
// current value per change. The realm decides who may call Set; this package
// decides whether the value is acceptable.
package params

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// Bps is the basis-point denominator.
const Bps = int64(10_000)

// Def describes one integer parameter.
type Def struct {
	Name         string
	Doc          string
	Default      int64
	Min          int64
	Max          int64
	MaxChangeBps int64 // 0: unlimited; otherwise |new - old| <= old * MaxChangeBps / Bps when old > 0
	Timelock     int64 // seconds the realm should wait before applying a change (informational here)
}

// Registry holds definitions and current values.
type Registry struct {
	defs   *avl.Tree // name -> *Def
	values *avl.Tree // name -> int64
	strs   *avl.Tree // name -> string (free-form parameters, e.g. a denom)
	order  []string  // definition order, for rendering
}

// New returns an empty registry.
func New() *Registry {
	return &Registry{defs: avl.NewTree(), values: avl.NewTree(), strs: avl.NewTree()}
}

// Define registers a parameter at its default. Defining a name twice panics.
func (r *Registry) Define(d Def) {
	if d.Name == "" || strings.ContainsAny(d.Name, " =\n") {
		panic("params: invalid name")
	}
	if r.defs.Has(d.Name) {
		panic("params: already defined: " + d.Name)
	}
	if d.Min > d.Max || d.Default < d.Min || d.Default > d.Max {
		panic("params: default out of bounds: " + d.Name)
	}
	if d.MaxChangeBps < 0 || d.MaxChangeBps > Bps {
		panic("params: max change out of range: " + d.Name)
	}
	dd := d
	r.defs.Set(d.Name, &dd)
	r.values.Set(d.Name, d.Default)
	r.order = append(r.order, d.Name)
}

// DefineString registers a free-form string parameter at its default.
func (r *Registry) DefineString(name, doc, def string) {
	r.Define(Def{Name: name, Doc: doc})
	r.strs.Set(name, def)
}

// Has reports whether name is defined.
func (r *Registry) Has(name string) bool { return r.defs.Has(name) }

// Def returns the definition.
func (r *Registry) Def(name string) Def {
	v := r.defs.Get(name)
	if v == nil {
		panic("params: unknown parameter: " + name)
	}
	return *(v.(*Def))
}

// Int returns the current value. Unknown names panic: a realm asking for a
// parameter it never defined is a programming error.
func (r *Registry) Int(name string) int64 {
	if r.strs.Has(name) {
		panic("params: not an integer parameter: " + name)
	}
	v := r.values.Get(name)
	if v == nil {
		panic("params: unknown parameter: " + name)
	}
	return v.(int64)
}

// Str returns a string parameter.
func (r *Registry) Str(name string) string {
	v := r.strs.Get(name)
	if v == nil {
		panic("params: unknown string parameter: " + name)
	}
	return v.(string)
}

// Check reports whether value would be accepted for name, without setting.
func (r *Registry) Check(name string, value int64) error {
	v := r.defs.Get(name)
	if v == nil {
		return errors.New("params: unknown parameter: " + name)
	}
	if r.strs.Has(name) {
		return errors.New("params: not an integer parameter: " + name)
	}
	d := v.(*Def)
	if value < d.Min || value > d.Max {
		return errors.New("params: " + name + " out of bounds [" + strconv.FormatInt(d.Min, 10) + ", " + strconv.FormatInt(d.Max, 10) + "]")
	}
	old := r.values.Get(name).(int64)
	if d.MaxChangeBps > 0 && old > 0 {
		diff := value - old
		if diff < 0 {
			diff = -diff
		}
		// diff * Bps <= old * MaxChangeBps; values are bounded so this cannot overflow in practice,
		// but compare via division to stay safe: diff <= old * MaxChangeBps / Bps (floor) means a
		// change of exactly the allowed fraction passes.
		limit := old / Bps * d.MaxChangeBps
		rem := old % Bps * d.MaxChangeBps / Bps
		limit += rem
		if diff > limit {
			return errors.New("params: " + name + " changes by more than " + strconv.FormatInt(d.MaxChangeBps, 10) + " bps of its current value")
		}
	}
	return nil
}

// Set changes an integer parameter after Check. It returns the old value.
func (r *Registry) Set(name string, value int64) (old int64, err error) {
	if err := r.Check(name, value); err != nil {
		return 0, err
	}
	old = r.values.Get(name).(int64)
	r.values.Set(name, value)
	return old, nil
}

// SetString changes a string parameter. It returns the old value.
func (r *Registry) SetString(name, value string) (old string, err error) {
	v := r.strs.Get(name)
	if v == nil {
		return "", errors.New("params: unknown string parameter: " + name)
	}
	if len(value) > 256 {
		return "", errors.New("params: string too long")
	}
	r.strs.Set(name, value)
	return v.(string), nil
}

// ParseAssignment splits "name=value" as a proposal payload.
func ParseAssignment(payload string) (name string, value int64, err error) {
	i := strings.IndexByte(payload, '=')
	if i <= 0 || i == len(payload)-1 {
		return "", 0, errors.New("params: payload must be name=value")
	}
	name = strings.TrimSpace(payload[:i])
	v, perr := strconv.ParseInt(strings.TrimSpace(payload[i+1:]), 10, 64)
	if perr != nil {
		return "", 0, errors.New("params: value is not an integer")
	}
	return name, v, nil
}

// Names lists parameters in definition order.
func (r *Registry) Names() []string {
	out := make([]string, len(r.order))
	copy(out, r.order)
	return out
}

// Markdown renders the registry as a table.
func (r *Registry) Markdown() string {
	var b strings.Builder
	b.WriteString("| parameter | value | bounds | max change | doc |\n|---|---|---|---|---|\n")
	for _, n := range r.order {
		d := r.defs.Get(n).(*Def)
		b.WriteString("| `" + n + "` | ")
		if r.strs.Has(n) {
			b.WriteString(r.strs.Get(n).(string) + " | | | ")
		} else {
			b.WriteString(strconv.FormatInt(r.values.Get(n).(int64), 10) + " | ")
			b.WriteString(strconv.FormatInt(d.Min, 10) + " to " + strconv.FormatInt(d.Max, 10) + " | ")
			if d.MaxChangeBps > 0 {
				b.WriteString(strconv.FormatInt(d.MaxChangeBps, 10) + " bps | ")
			} else {
				b.WriteString("any | ")
			}
		}
		b.WriteString(d.Doc + " |\n")
	}
	return b.String()
}

// JSON renders the current values as a flat object.
func (r *Registry) JSON() string {
	var b strings.Builder
	b.WriteString("{")
	for i, n := range r.order {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString("\"" + n + "\":")
		if r.strs.Has(n) {
			b.WriteString(strconv.Quote(r.strs.Get(n).(string)))
		} else {
			b.WriteString(strconv.FormatInt(r.values.Get(n).(int64), 10))
		}
	}
	b.WriteString("}")
	return b.String()
}

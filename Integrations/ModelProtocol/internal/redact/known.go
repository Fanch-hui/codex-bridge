package redact

import (
	"crypto/sha256"
	"fmt"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
)

const minKnown = 8

type knownValue struct{ v, p, kind string }

var (
	known = map[string][]knownValue{}

	knownBits [1 << 14]uint64

	knownGen atomic.Uint64
)

func gram(s string, i int) uint32 {
	g := uint32(s[i]) | uint32(s[i+1])<<8 | uint32(s[i+2])<<16 | uint32(s[i+3])<<24
	return (g * 2654435761) >> 12
}

func addKnown(p, v string) {
	kind := kindOf(p)
	if kind == "TERM" || len(v) < minKnown {
		return
	}
	head := v[:minKnown]
	for i, k := range known[head] {
		if k.v == v {

			if p < k.p {
				known[head][i] = knownValue{v, p, kind}
				knownGen.Add(1)
			}
			return
		}
	}
	known[head] = append(known[head], knownValue{v, p, kind})
	g := gram(v, 0)
	knownBits[g/64] |= 1 << (g % 64)
	knownGen.Add(1)
}

func reindexKnown() {
	known = map[string][]knownValue{}
	knownBits = [1 << 14]uint64{}
	knownGen.Add(1)
	for p, v := range values {
		addKnown(p, v)
	}
}

func kindOf(p string) string {
	if k, ok := shapes[p]; ok {
		return k
	}
	if i := strings.LastIndexByte(p, '_'); i > 2 {
		return p[2:i]
	}
	return ""
}

var kindCats = func() map[string][]string {
	m := map[string][]string{}
	for _, r := range rules {
		kinds := r.groups
		if len(kinds) == 0 {
			kinds = []string{r.kind}
		}
		for _, k := range kinds {
			if r.cat != "" && !slices.Contains(m[k], r.cat) {
				m[k] = append(m[k], r.cat)
			}
		}
	}

	for _, k := range modelKinds {
		if c := modelCat(k); c != "" && !slices.Contains(m[k], c) {
			m[k] = append(m[k], c)
		}
	}
	return m
}()

func (o Options) coversKind(kind string) bool {
	cats, ok := kindCats[kind]
	if !ok {
		return o.Secrets
	}
	for _, c := range cats {
		if o.covers(c) {
			return true
		}
	}
	return false
}

const ruleFound = 2

var scores = map[string]float64{}

func noteScores(s string, found []span) {
	if len(found) == 0 {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if len(scores) >= maxValues {

		scores = map[string]float64{}
	}
	for _, f := range found {
		if f.by == ByKnown || f.end-f.start < minKnown {
			continue
		}
		v, sc := s[f.start:f.end], float64(ruleFound)
		if f.by == ByModel && f.score > 0 {
			sc = f.score
		}
		if old, ok := scores[v]; !ok || sc > old {
			scores[v] = sc
		}
	}
}

func knownSpans(s string, o Options) []span {
	if !o.Secrets && !o.Personal || len(s) < minKnown {
		return nil
	}
	mu.RLock()
	defer mu.RUnlock()
	if len(known) == 0 {
		return nil
	}
	var out []span
	for i := 0; i+minKnown <= len(s); i++ {
		if g := gram(s, i); knownBits[g/64]&(1<<(g%64)) == 0 {
			continue
		}
		var best *knownValue
		for j, k := range known[s[i:i+minKnown]] {
			if !o.coversKind(k.kind) {
				continue
			}
			sc, scored := scores[k.v]
			if scored && sc < o.MinScore {
				continue
			}
			if scored && sc < ruleFound && k.kind == "SECRET" && wordsOnly(k.v) && !assignedSecret(s, i) {

				continue
			}
			if best != nil && len(k.v) <= len(best.v) || !strings.HasPrefix(s[i:], k.v) || !standsAlone(k.kind, s, i, i+len(k.v)) {
				continue
			}
			if packageAt(s, i, i+len(k.v)) {

				continue
			}
			best = &known[s[i:i+minKnown]][j]
		}
		if best != nil {
			out = append(out, span{i, i + len(best.v), best.kind, ByKnown, 0, false})
			i += len(best.v) - 1
		}
	}
	return out
}

func standsAlone(kind, s string, a, b int) bool {
	before, after := byte(0), byte(0)
	if a > 0 {
		before = s[a-1]
	}
	if b < len(s) {
		after = s[b]
	}
	is := func(c byte, set string) bool { return c != 0 && strings.IndexByte(set, c) >= 0 }
	switch kind {
	case "PHONE", "BANK_CARD", "ID_CARD", "IBAN", "SSN", "PASSPORT", "SERIAL":
		return !is(before, alnum) && !is(after, alnum)
	case "IP", "MAC":

		if is(before, alnum+".:") || is(after, alnum+":") {
			return false
		}
		return after != '.' || b+1 >= len(s) || !is(s[b+1], digits)
	case "USERNAME":
		return nameAlone(s, a, b)
	case "EMAIL":
		if is(before, alnum+"._%+-") || is(after, alnum+"_%+") {
			return false
		}

		return !is(after, ".-") || b+1 >= len(s) || !is(s[b+1], alnum)
	}
	return !(is(before, alnum) && is(s[a], alnum)) && !(is(after, alnum) && is(s[b-1], alnum))
}

const sentEntries = 1 << 17

const (
	sentModel byte = iota + 1
	sentKnown
)

var sentMemo struct {
	sync.Mutex
	cur, old map[[32]byte][]span
}

func sentSpans(what byte, s string, o Options, find func() []span) []span {
	if !o.Secrets && !o.Personal || what == sentKnown && len(s) < minKnown {
		if what == sentKnown {
			return nil
		}
		return find()
	}
	if what == sentModel && (o.Model == nil || o.Route == "") {

		return find()
	}
	h := sha256.New()
	fmt.Fprintf(h, "%d\x00%q\x00%t\x00%t\x00", what, o.Route, o.Secrets, o.Personal)
	if what == sentModel {
		fmt.Fprintf(h, "%t\x00%t\x00%g\x00", o.Model != nil, o.NamesByModel, o.MinScore)
	}
	kinds := make([]string, 0, len(o.Kinds))
	for k, on := range o.Kinds {
		kinds = append(kinds, fmt.Sprintf("%s=%t", k, on))
	}
	slices.Sort(kinds)
	fmt.Fprintf(h, "%s\x00", strings.Join(kinds, ","))
	h.Write([]byte(s))
	var k [32]byte
	h.Sum(k[:0])
	sentMemo.Lock()
	sp, ok := sentMemo.cur[k]
	if !ok {
		if sp, ok = sentMemo.old[k]; ok {
			sentAdd(k, sp)
		}
	}
	sentMemo.Unlock()
	if ok {
		return slices.Clone(sp)
	}
	sp = find()
	sentMemo.Lock()
	sentAdd(k, slices.Clone(sp))
	sentMemo.Unlock()
	return sp
}

func sentAdd(k [32]byte, sp []span) {
	if sentMemo.cur == nil || len(sentMemo.cur) >= sentEntries {
		sentMemo.old, sentMemo.cur = sentMemo.cur, make(map[[32]byte][]span)
	}
	sentMemo.cur[k] = sp
}

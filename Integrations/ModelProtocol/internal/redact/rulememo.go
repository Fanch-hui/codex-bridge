package redact

import (
	"crypto/sha256"
	"fmt"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
)

const (
	ruleMemoMin     = 256
	ruleMemoEntries = 1 << 16
)

var ruleMemo struct {
	sync.Mutex
	cur, old map[[32]byte][]span
}

var ruleRuns atomic.Uint64

func memoRules(s string, o Options, find func() []span) []span {
	if len(s) < ruleMemoMin {
		return find()
	}
	h := sha256.New()
	fmt.Fprintf(h, "%s\x00%t\x00%t\x00", dateClock().Format("2006-01-02"), o.Secrets, o.Personal)
	kinds := make([]string, 0, len(o.Kinds))
	for k, on := range o.Kinds {
		kinds = append(kinds, fmt.Sprintf("%q=%t", k, on))
	}
	slices.Sort(kinds)
	fmt.Fprintf(h, "%s\x00", strings.Join(kinds, ","))
	if o.Secrets {
		for _, r := range o.Rules {
			fmt.Fprintf(h, "%q:%q:%q;", r.Kind, r.Prefix, r.Regex)
		}
	}
	h.Write([]byte{0})
	h.Write([]byte(s))
	var k [32]byte
	h.Sum(k[:0])
	ruleMemo.Lock()
	sp, ok := ruleMemo.cur[k]
	if !ok {
		if sp, ok = ruleMemo.old[k]; ok {
			ruleAdd(k, sp)
		}
	}
	ruleMemo.Unlock()
	if ok {
		return slices.Clone(sp)
	}
	sp = find()
	ruleMemo.Lock()
	ruleAdd(k, slices.Clip(slices.Clone(sp)))
	ruleMemo.Unlock()
	return sp
}

func ruleAdd(k [32]byte, sp []span) {
	if ruleMemo.cur == nil || len(ruleMemo.cur) >= ruleMemoEntries {
		ruleMemo.old, ruleMemo.cur = ruleMemo.cur, make(map[[32]byte][]span)
	}
	ruleMemo.cur[k] = sp
}

package redact

import (
	"hash/maphash"
	"strings"
	"sync"
)

const allowKeptEntries = 1 << 17

type keptKey struct{ text, value uint64 }

var allowKept struct {
	sync.Mutex
	cur, old map[keptKey]struct{}
}

var keptSeed = maphash.MakeSeed()

func keptText(route, s string) uint64 {
	var h maphash.Hash
	h.SetSeed(keptSeed)
	h.WriteString(route)
	h.WriteByte(0)
	h.WriteString(s)
	return h.Sum64()
}

func keptValue(v string) uint64 {
	return maphash.String(keptSeed, strings.ToLower(strings.TrimSpace(v)))
}

func maskedBefore(text uint64, v string) bool {
	k := keptKey{text, keptValue(v)}
	allowKept.Lock()
	defer allowKept.Unlock()
	if _, ok := allowKept.cur[k]; ok {
		return true
	}
	if _, ok := allowKept.old[k]; ok {
		keptAdd(k)
		return true
	}
	return false
}

func keepMasked(text uint64, v string) {
	k := keptKey{text, keptValue(v)}
	allowKept.Lock()
	defer allowKept.Unlock()
	if _, ok := allowKept.cur[k]; !ok {
		keptAdd(k)
	}
}

func keptAdd(k keptKey) {
	if allowKept.cur == nil || len(allowKept.cur) >= allowKeptEntries {
		allowKept.old, allowKept.cur = allowKept.cur, make(map[keptKey]struct{})
	}
	allowKept.cur[k] = struct{}{}
}

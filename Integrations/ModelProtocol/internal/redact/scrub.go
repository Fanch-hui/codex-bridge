package redact

import (
	"crypto/sha256"
	"strings"
	"sync"
	"sync/atomic"

	"codexbridge/modelprotocol/internal/lazyre"
)

const Scrubbed = "[REDACTED]"

func scrubbed(kind, _ string) string { return "[REDACTED:" + kind + "]" }

var secretName = lazyre.New(`(?i)` + secretNames.pattern() + `|authori[sz]ation|cookie|^key$|^pass$|_pass$`)

func SecretName(name string) bool {
	n := strings.ToLower(name)
	return secretName.MatchString(n) && !strings.HasSuffix(n, "tokens") && !strings.HasSuffix(n, "token_count")
}

func Scrub(s string) string {
	if len(s) < scrubMemoMin {
		return scrub(s)
	}

	gen := knownGen.Load()
	k := sha256.Sum256([]byte(s))
	if out, ok := scrubMemo.get(k, gen, s); ok {
		return out
	}
	out := scrub(s)
	scrubMemo.put(k, gen, s, out)
	return out
}

func scrub(s string) string {
	if len(s) >= 256 {
		scrubRuns.Add(1)
	}
	out, _ := mask(s, Options{Secrets: true}, scrubbed, false)
	return out
}

var scrubRuns atomic.Uint64

const (
	scrubMemoMin     = 256
	scrubMemoEntries = 1 << 15
	scrubMemoBytes   = 32 << 20
)

type scrubEntry struct {
	gen  uint64
	same bool
	out  string
}

var scrubMemo memo

type memo struct {
	sync.Mutex
	cur, old map[[32]byte]scrubEntry
	bytes    int
}

func (m *memo) get(k [32]byte, gen uint64, s string) (string, bool) {
	m.Lock()
	defer m.Unlock()
	e, ok := m.cur[k]
	if !ok {
		if e, ok = m.old[k]; ok && e.gen == gen {
			m.add(k, e)
		}
	}
	if !ok || e.gen != gen {
		return "", false
	}
	if e.same {
		return s, true
	}
	return e.out, true
}

func (m *memo) put(k [32]byte, gen uint64, s, out string) {
	e := scrubEntry{gen: gen, same: out == s}
	if !e.same {
		e.out = strings.Clone(out)
	}
	m.Lock()
	defer m.Unlock()
	m.add(k, e)
}

func (m *memo) add(k [32]byte, e scrubEntry) {
	if m.cur == nil || len(m.cur) >= scrubMemoEntries || m.bytes+len(e.out) > scrubMemoBytes {
		m.old, m.cur, m.bytes = m.cur, make(map[[32]byte]scrubEntry), 0
	}
	m.bytes += len(e.out) - len(m.cur[k].out)
	m.cur[k] = e
}

func ScrubJSON(body []byte) []byte {
	if out, ok := scrubJSON(body); ok {
		return out
	}
	lines := strings.SplitAfter(string(body), "\n")
	for i, l := range lines {
		if rest, ok := strings.CutPrefix(l, "data:"); ok {
			trimmed := strings.TrimSpace(rest)
			if out, ok := scrubJSON([]byte(trimmed)); ok && trimmed != "" {
				lines[i] = "data: " + string(out) + l[len(strings.TrimRight(l, "\r\n")):]
				continue
			}
		}
		lines[i] = Scrub(l)
	}
	return []byte(strings.Join(lines, ""))
}

func scrubJSON(b []byte) ([]byte, bool) {
	return walk(b, func(_, key, s string) string {
		switch {
		case strings.HasPrefix(s, "data:"):
			return s
		case key != "" && SecretName(key):
			return Scrubbed
		}
		return Scrub(s)
	})
}

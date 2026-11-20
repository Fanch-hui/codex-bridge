package redact

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"net/netip"
	"slices"
	"strings"

	"codexbridge/modelprotocol/internal/lazyre"
)

const (
	minShape  = 8
	minRandom = 6
)

var (
	shapes = map[string]string{}
)

var keyPrefixes = []string{"sk-ant-api03-", "sk-ant-oat01-", "sk-ant-admin01-", "sk-proj-", "sk-svcacct-", "sk-or-v1-", "github_pat_"}

func keyHead(v string) string {
	for _, p := range keyPrefixes {
		if strings.HasPrefix(v, p) {
			return p
		}
	}
	if strings.HasPrefix(v, "AKIA") || strings.HasPrefix(v, "ASIA") {
		return v[:4]
	}
	for i := 0; i < len(v) && i <= 4; i++ {
		c := v[i]
		if (c == '-' || c == '_') && i > 0 {
			return v[:i+1]
		}
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			break
		}
	}
	return ""
}

var namedValue = lazyre.New(`^[A-Za-z_][A-Za-z0-9_.-]*[ \t]*[=:][ \t]*()`)

func splitName(v string) (name, key string) {
	if m := namedValue.FindStringSubmatchIndex(v); m != nil {
		return v[:m[2]], v[m[2]:]
	}
	return "", v
}

func shapeByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.'
}

func shapeOf(kind, v string) (string, bool) {
	if _, personal := kindCats[kind]; personal || kind == "TERM" || len(v) < minShape {
		return "", false
	}
	for i := 0; i < len(v); i++ {
		if !shapeByte(v[i]) {
			return "", false
		}
	}
	head := keyHead(v)
	rest := v[len(head):]

	hexLower, hexUpper := true, true
	for i := 0; i < len(rest); i++ {
		c := rest[i]
		switch {
		case c >= '0' && c <= '9', c == '-' || c == '_' || c == '.':
		case c >= 'a' && c <= 'f':
			hexUpper = false
		case c >= 'A' && c <= 'F':
			hexLower = false
		default:
			hexLower, hexUpper = false, false
		}
	}
	h := hmac.New(sha256.New, key())
	h.Write([]byte("shape\x00" + kind + "\x00" + v))
	seed := h.Sum(nil)
	var stream []byte
	n := 0
	next := func(k int) byte {
		if len(stream) == 0 {
			h := hmac.New(sha256.New, seed)
			var c [8]byte
			binary.BigEndian.PutUint64(c[:], uint64(n))
			n++
			h.Write(c[:])
			stream = h.Sum(nil)
		}
		b := stream[0]
		stream = stream[1:]
		return b % byte(k)
	}
	const (
		upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
		lower = "abcdefghijklmnopqrstuvwxyz"
		digit = "0123456789"
	)
	out, made := []byte(head), 0
	for i := 0; i < len(rest); i++ {
		c := rest[i]
		set := ""
		switch {
		case c == '-' || c == '_' || c == '.':
		case hexLower:
			set = digit + "abcdef"
		case hexUpper:
			set = digit + "ABCDEF"
		case c >= 'A' && c <= 'Z':
			set = upper
		case c >= 'a' && c <= 'z':
			set = lower
		default:
			set = digit
		}
		if set == "" {
			out = append(out, c)
			continue
		}
		made++
		out = append(out, set[next(len(set))])
	}
	if made < minRandom {
		return "", false
	}
	f := string(out)
	return f, f != v
}

func shaped(kind, v string) string {
	name, k := splitName(v)
	f, ok := shapeOf(kind, k)
	if !ok {
		return placeholder(kind, v)
	}
	mu.Lock()
	have, taken := values[f]
	if !taken {
		makeRoom()
		values[f] = k
		kinds[kind] = true
		shapes[f] = kind
		addKnown(f, k)
	}
	touch(f)
	mu.Unlock()
	if taken && have != k {

		return placeholder(kind, v)
	}
	return name + f
}

func foldStandIn(kind string) bool { return kind == "USERNAME" || kind == "IP" }

func outsideShapes(s string, found []span) []span {
	mu.RLock()
	defer mu.RUnlock()
	lower := lowerASCII(s)
	for f, kind := range shapes {
		in := s
		if foldStandIn(kind) {
			in = lower
		}
		for i := 0; ; {
			a := strings.Index(in[i:], f)
			if a < 0 {
				break
			}
			a += i
			z := a + len(f)
			found = slices.DeleteFunc(found, func(x span) bool { return x.start < z && x.end > a })
			i = z
		}
	}
	return found
}

const standInLen = 8

func standInOf(v string) string {
	h := hmac.New(sha256.New, key())
	h.Write([]byte("user\x00" + v))
	sum := h.Sum(nil)
	out := make([]byte, standInLen)
	for i := range out {
		out[i] = 'a' + sum[i]%26
	}
	return string(out)
}

const (
	ipStandInHead = "public-ip-"
	ipStandInLen  = 8
)

func ipStandIns(v string) (at func(i int) string, n int, ok bool) {
	a, err := netip.ParseAddr(v)
	if err != nil {
		return nil, 0, false
	}
	k := key()
	return func(i int) string {
		h := hmac.New(sha256.New, k)
		h.Write([]byte("ip\x00" + a.Unmap().String()))
		var c [8]byte
		binary.BigEndian.PutUint64(c[:], uint64(i))
		h.Write(c[:])
		sum := h.Sum(nil)
		out := []byte(ipStandInHead)
		for j := 0; j < ipStandInLen; j++ {
			out = append(out, 'a'+sum[j]%26)
		}
		return string(out)
	}, 8, true
}

func ipStandIn(v string) (string, bool) {
	at, n, ok := ipStandIns(v)
	if !ok {
		return "", false
	}
	mu.Lock()
	defer mu.Unlock()
	free := ""
	for i := 0; i < n; i++ {
		f := at(i)
		have, taken := values[f]
		if taken && have == v {
			touch(f)
			return f, true
		}
		if !taken && free == "" {
			free = f
		}
	}
	if free == "" {
		return "", false
	}
	makeRoom()
	values[free] = v
	kinds["IP"] = true
	shapes[free] = "IP"
	addKnown(free, v)
	touch(free)
	return free, true
}

func standIn(put func(kind, v string) string) func(kind, v string) string {
	return func(kind, v string) string {
		if kind == "IP" {
			if f, ok := ipStandIn(v); ok {
				return f
			}
			return put(kind, v)
		}
		if kind != "USERNAME" {
			return put(kind, v)
		}
		f := standInOf(v)
		if f == v {
			return put(kind, v)
		}
		mu.Lock()
		have, taken := values[f]
		if !taken {
			makeRoom()
			values[f] = v
			kinds[kind] = true
			shapes[f] = kind
			addKnown(f, v)
		}
		touch(f)
		mu.Unlock()
		if taken && have != v {
			return put(kind, v)
		}
		return f
	}
}

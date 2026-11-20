package redact

import (
	"slices"
	"strings"
)

func noIDs(s string, found []span) []span {
	return slices.DeleteFunc(found, func(f span) bool {
		if f.by == ByWord || f.by == ByYours {
			return false
		}
		l, r, ok := idAround(s, f.start, f.end)
		if !ok {
			return false
		}
		if f.start > l || f.end < r {
			return true
		}
		switch f.by {
		case ByKnown:

			return elementToken(s, l, r)
		case ByModel:

			return f.kind != "SECRET" || uuidRe.MatchString(s[l:r]) || elementToken(s, l, r) ||
				len(fieldWords(s, l)) > 0 && !credentialField(s, l) || nameOfField(s, l, r)
		case ByRule:
			switch f.kind {
			case "PASSWORD", "API_KEY", "TOKEN", "PRIVATE_KEY":
				return false
			case "WALLET_KEY":

				return false
			case "SECRET":

				if digestShaped(s[l:r]) && len(fieldWords(s, l)) == 0 {
					return false
				}
				return !credentialField(s, l)
			}
		}
		return true
	})
}

func idAround(s string, a, b int) (l, r int, ok bool) {
	if elementToken(s, a, b) {
		return a, b, true
	}
	l, r = a, b
	for l > 0 && hexOrHyphen(s[l-1]) {
		l--
	}
	for r < len(s) && hexOrHyphen(s[r]) {
		r++
	}
	for l < r && s[l] == '-' {
		l++
	}
	for r > l && s[r-1] == '-' {
		r--
	}
	if a < l || b > r || strings.IndexFunc(s[l:r], func(c rune) bool { return c > 0x7f || !hexOrHyphen(byte(c)) }) >= 0 ||
		!idShaped(s[l:r]) {
		return 0, 0, false
	}

	if digestShaped(s[l:r]) && (l > 0 && wordByte(s[l-1]) || r < len(s) && wordByte(s[r])) {
		return 0, 0, false
	}
	return l, r, true
}

func nameOfField(s string, l, r int) bool {
	if l == 0 || s[l-1] != '"' {
		return false
	}
	i := r
	if i < len(s) && s[i] == '\\' {
		i++
	}
	if i >= len(s) || s[i] != '"' {
		return false
	}
	i++
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	return i < len(s) && s[i] == ':'
}

func elementToken(s string, a, b int) bool {
	if b-a < 9 || s[a] != 's' || a > 0 && wordByte(s[a-1]) {
		return false
	}
	for _, c := range []byte(s[a+1 : a+9]) {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	end := a + 9
	if end < len(s) && s[end] == ':' {
		i := end + 1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		if i == end+1 {
			return false
		}
		end = i
	}
	if b != a+9 && b != end || end < len(s) && wordByte(s[end]) {
		return false
	}
	return end > a+9 || elementField(fieldWords(s, a))
}

func elementField(words []string) bool {
	return slices.Equal(words, []string{"element", "token"})
}

func hexOrHyphen(c byte) bool {
	return c == '-' || c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

func idShaped(v string) bool {
	return uuidRe.MatchString(v) || len(v) >= 32 && !strings.Contains(v, "-") || digestShaped(v)
}

func digestShaped(v string) bool {
	if len(v) < 16 || len(v) >= 32 {
		return false
	}
	var lower, upper, digits int
	for i := 0; i < len(v); i++ {
		switch c := v[i]; {
		case c >= '0' && c <= '9':
			digits++
		case c >= 'a' && c <= 'f':
			lower++
		case c >= 'A' && c <= 'F':
			upper++
		default:
			return false
		}
	}

	letters := lower + upper
	return (lower == 0 || upper == 0) && letters >= max(3, len(v)/8) && digits >= max(3, len(v)/8)
}

func credentialField(s string, at int) bool {
	words := fieldWords(s, at)
	if len(words) == 1 && words[0] == "key" && keyPhrase(s, at) {
		return true
	}
	if len(words) < 2 && (len(words) == 0 || words[0] == "key") || elementField(words) {
		return false
	}
	switch words[len(words)-1] {
	case "id", "ids", "uuid", "guid":
		return false
	}
	for _, w := range words {
		switch w {
		case "page", "next", "cursor", "continuation", "csrf", "xsrf", "trace", "request", "idempotency", "sync", "nonce",
			"hash", "digest", "checksum", "sha", "fingerprint", "etag",

			"cache", "commit", "object", "blob", "file", "content", "revision", "rev", "partition", "shard", "bucket", "dedup", "dedupe", "lookup", "row", "sort":
			return false
		}
	}
	return true
}

func keyPhrase(s string, at int) bool {
	before := strings.ToLower(s[max(0, at-24):at])
	i := strings.LastIndex(before, "key")
	if i < 0 {
		return false
	}
	before = strings.TrimRight(before[:i], " ")
	for _, w := range []string{"api", "access", "secret", "private", "signing", "license", "licence"} {
		if strings.HasSuffix(before, w) && (len(before) == len(w) || !wordByte(before[len(before)-len(w)-1])) {
			return true
		}
	}
	return false
}

func fieldWords(s string, at int) []string {
	i := at
	for i > 0 && strings.IndexByte(" \t\"'\\", s[i-1]) >= 0 {
		i--
	}
	if i == 0 || s[i-1] != ':' && s[i-1] != '=' {
		return nil
	}
	i--
	for i > 0 && strings.IndexByte(" \t\"'\\", s[i-1]) >= 0 {
		i--
	}
	j := i
	for j > 0 && strings.IndexByte(alnum+"_.-", s[j-1]) >= 0 {
		j--
	}
	return nameWords(s[j:i])
}

func nameWords(name string) []string {
	var out []string
	w := []byte{}
	flush := func() {
		if len(w) > 0 {
			out = append(out, string(w))
			w = w[:0]
		}
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		switch {
		case c == '_' || c == '-' || c == '.':
			flush()
		case c >= 'A' && c <= 'Z':
			if i > 0 && name[i-1] >= 'a' && name[i-1] <= 'z' {
				flush()
			}
			w = append(w, c+'a'-'A')
		default:
			w = append(w, c)
		}
	}
	flush()
	return out
}

package redact

import (
	"bytes"
	"encoding/json"

	"strconv"
	"strings"
)

func walk(b []byte, fn func(path, key, s string) string) (out []byte, ok bool) {
	w := walker{in: b, fn: fn}
	i, good := w.value(w.ws(0), "", "")
	if !good || w.ws(i) != len(b) {
		return b, false
	}
	if w.last == 0 {
		return b, true
	}
	w.out.Write(b[w.last:])
	out = w.out.Bytes()
	if cap(out)-len(out) > len(out)/8 {

		out = bytes.Clone(out)
	}
	return out, true
}

type walker struct {
	in   []byte
	out  bytes.Buffer
	last int
	fn   func(path, key, s string) string
}

func (w *walker) ws(i int) int {
	for i < len(w.in) && (w.in[i] == ' ' || w.in[i] == '\t' || w.in[i] == '\n' || w.in[i] == '\r') {
		i++
	}
	return i
}

func join(path, k string) string {
	if path == "" {
		return k
	}
	return path + "." + k
}

func (w *walker) str(i int) (end int, escaped, ok bool) {
	for j := i + 1; j < len(w.in); j++ {
		switch w.in[j] {
		case '\\':
			escaped = true
			j++
		case '"':
			return j + 1, escaped, true
		}
	}
	return 0, false, false
}

func (w *walker) value(i int, path, key string) (int, bool) {
	if i >= len(w.in) {
		return i, false
	}
	switch c := w.in[i]; c {
	case '{':
		i = w.ws(i + 1)
		if i < len(w.in) && w.in[i] == '}' {
			return i + 1, true
		}
		for {
			if i >= len(w.in) || w.in[i] != '"' {
				return i, false
			}
			end, esc, ok := w.str(i)
			if !ok {
				return i, false
			}
			k := string(w.in[i+1 : end-1])
			if esc {
				if json.Unmarshal(w.in[i:end], &k) != nil {
					return i, false
				}
			}
			i = w.ws(end)
			if i >= len(w.in) || w.in[i] != ':' {
				return i, false
			}
			if i, ok = w.value(w.ws(i+1), join(path, k), k); !ok {
				return i, false
			}
			i = w.ws(i)
			if i < len(w.in) && w.in[i] == ',' {
				i = w.ws(i + 1)
				continue
			}
			if i < len(w.in) && w.in[i] == '}' {
				return i + 1, true
			}
			return i, false
		}
	case '[':
		i = w.ws(i + 1)
		if i < len(w.in) && w.in[i] == ']' {
			return i + 1, true
		}
		for n := 0; ; n++ {
			var ok bool

			if i, ok = w.value(i, join(path, strconv.Itoa(n)), key); !ok {
				return i, false
			}
			i = w.ws(i)
			if i < len(w.in) && w.in[i] == ',' {
				i = w.ws(i + 1)
				continue
			}
			if i < len(w.in) && w.in[i] == ']' {
				return i + 1, true
			}
			return i, false
		}
	case '"':
		end, esc, ok := w.str(i)
		if !ok {
			return i, false
		}
		s := string(w.in[i+1 : end-1])
		if esc && json.Unmarshal(w.in[i:end], &s) != nil {
			return i, false
		}
		if t := w.fn(path, key, s); t != s {
			if w.out.Cap() == 0 {

				w.out.Grow(len(w.in) + len(w.in)/16 + 64)
			}
			w.out.Write(w.in[w.last:i])
			w.out.WriteByte('"')
			w.out.WriteString(jsonEscape(t))
			w.out.WriteByte('"')
			w.last = end
		}
		return end, true
	default:
		j := i
		for j < len(w.in) && !strings.ContainsRune(",]} \t\r\n", rune(w.in[j])) {
			j++
		}
		if j == i {
			return i, false
		}
		return j, true
	}
}

func jsonEscape(s string) string {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	_ = e.Encode(s)
	out := b.Bytes()
	return string(out[1 : len(out)-2])
}

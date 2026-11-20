package gateway

import (
	"encoding/json"
	"strconv"
	"unicode/utf8"
)

type customStream struct {
	pend  []byte
	depth int
	str   bool
	esc   bool
	key   []byte
	inKey bool
	want  bool
	last  string
	value bool
	in    bool
	over  bool
}

func (c *customStream) feed(s string) string {
	if c.over {
		return ""
	}
	if c.in {
		c.pend = append(c.pend, s...)
		return c.take()
	}
	for i := 0; i < len(s); i++ {
		b := s[i]
		switch {
		case c.str:
			if c.inKey {
				c.key = append(c.key, b)
			}
			switch {
			case c.esc:
				c.esc = false
			case b == '\\':
				c.esc = true
			case b == '"':
				c.str = false
				if c.inKey {
					c.inKey = false
					c.last = ""
					json.Unmarshal(append([]byte{'"'}, c.key...), &c.last)
				}
			}
		case b == '"' && (c.depth == 0 || c.depth == 1 && c.value):
			c.in = true
			c.pend = append(c.pend, s[i+1:]...)
			return c.take()
		case b == '"':
			c.str = true
			if c.depth == 1 && c.want {
				c.inKey, c.key, c.want = true, c.key[:0], false
			}
		case b == '{' || b == '[':
			c.depth++
			if c.depth == 1 && b == '{' {
				c.want = true
			}
		case b == '}' || b == ']':
			if c.depth--; c.depth <= 0 {
				c.over = true
				return ""
			}
		case b == ':' && c.depth == 1:
			c.value = c.last == "input"
		case b == ',' && c.depth == 1:
			c.want, c.value = true, false
		case b == ' ' || b == '\t' || b == '\n' || b == '\r':
		case c.depth == 0:
			c.over = true
			return ""
		case c.depth == 1:
			c.value = false
		}
	}
	return ""
}

func (c *customStream) take() string {
	n, end := 0, false
scan:
	for n < len(c.pend) {
		switch c.pend[n] {
		case '"':
			end = true
			break scan
		case '\\':
			switch {
			case n+1 >= len(c.pend):
				break scan
			case c.pend[n+1] != 'u':
				n += 2
			case n+6 > len(c.pend):
				break scan
			case !highSurrogate(c.pend[n+2 : n+6]):
				n += 6
			case n+8 > len(c.pend):
				break scan
			case c.pend[n+6] != '\\' || c.pend[n+7] != 'u':
				n += 6
			case n+12 > len(c.pend):
				break scan
			default:
				n += 12
			}
		default:
			n++
		}
	}

	for k := 0; k < utf8.UTFMax-1 && n > 0 && !end && !utf8.Valid(c.pend[:n]); k++ {
		n--
	}
	var text string
	if json.Unmarshal(append(append([]byte{'"'}, c.pend[:n]...), '"'), &text) != nil {
		c.over = true
		return ""
	}
	c.pend = c.pend[n:]
	if end {
		c.over, c.pend = true, nil
	}
	return text
}

func highSurrogate(hex []byte) bool {
	r, err := strconv.ParseUint(string(hex), 16, 16)
	return err == nil && r >= 0xD800 && r < 0xDC00
}

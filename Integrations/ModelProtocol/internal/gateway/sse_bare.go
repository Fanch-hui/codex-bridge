package gateway

import (
	"bytes"
	"encoding/json"
	"io"
)

const bareLimit = 1 << 20

func bareErrors(r io.Reader) io.Reader {
	return &bareErrorReader{r: r, blank: true}
}

type bareErrorReader struct {
	r   io.Reader
	in  []byte
	out []byte
	err error

	mid bool

	bare []byte

	blank   bool
	scratch []byte
}

func (b *bareErrorReader) Read(p []byte) (int, error) {
	for len(b.out) == 0 {
		if b.err != nil {
			if len(b.in) > 0 || len(b.bare) > 0 {
				b.judge(true)
				continue
			}
			return 0, b.err
		}
		if b.scratch == nil {
			b.scratch = make([]byte, 32<<10)
		}
		n, err := b.r.Read(b.scratch)
		b.in = append(b.in, b.scratch[:n]...)
		b.err = err
		if n > 0 {
			b.judge(false)
		}
	}
	n := copy(p, b.out)
	b.out = b.out[n:]
	if len(b.out) == 0 {
		b.out = nil
	}
	return n, nil
}

func (b *bareErrorReader) judge(eof bool) {
	for len(b.in) > 0 || eof && len(b.bare) > 0 {
		i := bytes.IndexByte(b.in, '\n')
		if b.mid {

			if i < 0 {
				b.out = append(b.out, b.in...)
				b.in = b.in[:0]
				return
			}
			b.out = append(b.out, b.in[:i+1]...)
			b.in = b.in[i+1:]
			b.mid, b.blank = false, false
			continue
		}
		var line []byte
		switch {
		case i >= 0:
			line, b.in = b.in[:i+1], b.in[i+1:]
		case eof:
			line, b.in = b.in, b.in[:0]
		case b.bare == nil && !mayBeBare(b.in):

			b.out = append(b.out, b.in...)
			b.in = b.in[:0]
			b.mid = true
			return
		default:
			return
		}
		t := bytes.TrimSpace(line)
		if b.bare != nil {
			if len(t) == 0 || sseField(t) {

				b.release()
			} else {
				b.bare = append(b.bare, line...)
				b.settle()
				continue
			}
		}
		if len(line) == 0 {
			continue
		}
		if len(t) > 0 && (t[0] == '{' || t[0] == '[') {
			b.bare = append([]byte{}, line...)
			b.settle()
			continue
		}
		b.out = append(b.out, line...)
		b.blank = len(t) == 0
	}
}

func (b *bareErrorReader) settle() {
	t := bytes.TrimSpace(b.bare)
	if !json.Valid(t) {
		if len(b.bare) > bareLimit {
			b.release()
		}
		return
	}
	data, ok := bareError(t)
	if !ok {
		b.release()
		return
	}
	if !b.blank {
		b.out = append(b.out, '\n')
	}
	b.out = append(b.out, "data: "...)
	b.out = append(b.out, data...)
	b.out = append(b.out, "\n\n"...)
	b.bare, b.blank = nil, true
}

func (b *bareErrorReader) release() {
	b.out = append(b.out, b.bare...)
	b.blank = len(bytes.TrimSpace(b.bare)) == 0
	b.bare = nil
}

func mayBeBare(start []byte) bool {
	t := bytes.TrimLeft(start, " \t\r")
	return len(t) == 0 || t[0] == '{' || t[0] == '['
}

func sseField(t []byte) bool {
	for _, f := range [][]byte{[]byte("data:"), []byte("event:"), []byte("id:"), []byte("retry:"), []byte(":")} {
		if bytes.HasPrefix(t, f) {
			return true
		}
	}
	return false
}

func bareError(t []byte) ([]byte, bool) {
	if len(t) > 0 && t[0] == '[' {
		var list []json.RawMessage
		if json.Unmarshal(t, &list) != nil || len(list) != 1 {
			return nil, false
		}
		t = bytes.TrimSpace(list[0])
	}
	if len(t) == 0 || t[0] != '{' {
		return nil, false
	}
	var v struct {
		Type  json.RawMessage `json:"type"`
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal(t, &v) != nil {
		return nil, false
	}
	var typ string
	json.Unmarshal(v.Type, &typ)
	if !carries(v.Error) && typ != "error" {
		return nil, false
	}
	var one bytes.Buffer
	if json.Compact(&one, t) != nil {
		return nil, false
	}
	return one.Bytes(), true
}

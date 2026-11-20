package gateway

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

func readSSE(r io.Reader, fn func(event, data string) error) error {
	return readSSEAlive(r, fn, nil)
}

func readSSEAlive(r io.Reader, fn func(event, data string) error, alive func()) error {
	if _, ok := r.(*bareErrorReader); !ok {
		r = bareErrors(r)
	}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64<<10), 32<<20)
	var event string
	var data []string
	flush := func() error {
		if len(data) == 0 {
			event = ""
			return nil
		}
		err := fn(event, strings.Join(data, "\n"))
		event, data = "", nil
		if err == nil && alive != nil {
			alive()
		}
		return err
	}
	for sc.Scan() {
		line := sc.Text()
		switch {
		case line == "":
			if err := flush(); err != nil {
				return err
			}
		case strings.HasPrefix(line, ":"):
			if alive != nil {
				alive()
			}
		case strings.HasPrefix(line, "event:"):
			event = strings.TrimSpace(line[6:])
		case strings.HasPrefix(line, "data:"):
			data = append(data, strings.TrimPrefix(line[5:], " "))
		}
	}
	if err := flush(); err != nil {
		return err
	}
	return sc.Err()
}

type sseWriter struct {
	w     http.ResponseWriter
	f     http.Flusher
	begun bool
	wrote time.Time
}

func newSSEWriter(w http.ResponseWriter) *sseWriter {
	f, _ := w.(http.Flusher)
	return &sseWriter{w: w, f: f}
}

func (s *sseWriter) begin() {
	if s.begun {
		return
	}
	s.begun = true
	h := s.w.Header()
	h.Set("Content-Type", "text/event-stream; charset=utf-8")
	h.Set("Cache-Control", "no-cache")
	if h.Get("Connection") == "" {
		h.Set("Connection", "keep-alive")
	}
	h.Set("X-Accel-Buffering", "no")
	s.w.WriteHeader(http.StatusOK)
	s.flush()
	s.wrote = time.Now()
}

func (s *sseWriter) flush() {
	if s.f != nil {
		s.f.Flush()
	}
}

func (s *sseWriter) event(name string, v any) {
	s.begin()
	var b bytes.Buffer
	if name != "" {
		b.WriteString("event: ")
		b.WriteString(name)
		b.WriteByte('\n')
	}
	b.WriteString("data: ")
	switch x := v.(type) {
	case string:
		b.WriteString(x)
	case []byte:
		b.Write(x)
	case json.RawMessage:
		b.Write(x)
	default:
		j, _ := json.Marshal(x)
		b.Write(j)
	}
	b.WriteString("\n\n")
	s.w.Write(b.Bytes())
	s.flush()
	s.wrote = time.Now()
}

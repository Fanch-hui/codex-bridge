package gateway

import (
	"strings"
)

const citedTextMost = 150

type citer struct {
	hits []Hit
	line string
	held string
}

func (c *citer) on() bool { return len(c.hits) > 0 }

func (c *citer) feed(text string, say func(text string, cites []map[string]any, tail bool)) {
	c.line += text
	for {
		i := strings.IndexByte(c.line, '\n')
		if i < 0 {
			return
		}
		line := c.line[:i+1]
		c.line = c.line[i+1:]
		c.end(line, say)
	}
}

func (c *citer) end(line string, say func(string, []map[string]any, bool)) {
	if strings.TrimSpace(line) == "" {
		c.held += line
		return
	}
	line, c.held = c.held+line, ""
	say(line, citesOf(line, c.hits), false)
}

func (c *citer) flush(say func(string, []map[string]any, bool)) {
	line := c.line
	c.line = ""
	if strings.TrimSpace(line) != "" {
		c.end(line, say)
		return
	}
	if rest := c.held + line; rest != "" {
		c.held = ""
		say(rest, nil, true)
	}
}

func citesOf(line string, hits []Hit) []map[string]any {
	type at struct {
		i int
		h Hit
	}
	var found []at
	seen := map[string]bool{}
	for _, h := range hits {
		u := strings.TrimSuffix(h.URL, "/")
		if u == "" || seen[u] {
			continue
		}
		if i := urlIn(line, u); i >= 0 {
			seen[u] = true
			found = append(found, at{i, h})
		}
	}
	if len(found) == 0 {
		return nil
	}

	for i := 1; i < len(found); i++ {
		for j := i; j > 0 && found[j].i < found[j-1].i; j-- {
			found[j], found[j-1] = found[j-1], found[j]
		}
	}
	cites := make([]map[string]any, 0, len(found))
	for _, f := range found {
		cites = append(cites, map[string]any{"type": "web_search_result_location", "url": f.h.URL, "title": f.h.Title,
			"encrypted_index": "", "cited_text": firstRunes(strings.TrimSpace(f.h.Cited), citedTextMost)})
	}
	return cites
}

func urlIn(line, u string) int {
	for from := 0; ; {
		i := strings.Index(line[from:], u)
		if i < 0 {
			return -1
		}
		i += from
		rest := line[i+len(u):]
		if urlEnds(strings.TrimPrefix(rest, "/")) {
			return i
		}
		from = i + 1
	}
}

func urlEnds(rest string) bool {
	rest = strings.TrimLeft(rest, ".,;:!?*_")
	return rest == "" || rest[0] >= 0x80 || strings.IndexByte(" \t\r\n)]}>\"'`|", rest[0]) >= 0
}

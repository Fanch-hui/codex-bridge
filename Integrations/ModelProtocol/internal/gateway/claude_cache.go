package gateway

import (
	"encoding/json"
	"fmt"
)

type clientCache struct {
	system          []cachePoint
	tail            string
	count           int
	tools           int
	messages        int
	droppedSystem   int
	droppedMessages int
	systemMarks     int
	fresh           bool

	pasted bool

	print bool

	kept   bool
	report func()
}

type cachePoint struct {
	End int
	TTL string
}

func cacheTTL(cc map[string]string) string {
	if cc["type"] != "ephemeral" {
		return ""
	}
	if cc["ttl"] == "" {
		return "5m"
	}
	return cc["ttl"]
}

func askedCacheTTL(a *aRequest) string {
	ttl := ""
	take := func(raw json.RawMessage) {
		if len(raw) == 0 || ttl == "1h" {
			return
		}
		var cc map[string]string
		if json.Unmarshal(raw, &cc) != nil {
			return
		}
		switch t := cacheTTL(cc); t {
		case "5m", "1h":
			if ttl == "" || t == "1h" {
				ttl = t
			}
		}
	}
	take(a.CacheControl)
	for _, t := range a.Tools {
		take(t.CacheControl)
	}
	if bodyHasBytes(a.System, cacheControlField) {
		var system []struct {
			CacheControl json.RawMessage `json:"cache_control"`
		}
		if json.Unmarshal(a.System, &system) == nil {
			for _, b := range system {
				take(b.CacheControl)
			}
		}
	}
	for _, m := range a.Messages {
		if ttl == "1h" {
			break
		}
		if !bodyHasBytes(m.Content, cacheControlField) {
			continue
		}
		var blocks []struct {
			CacheControl json.RawMessage `json:"cache_control"`
		}
		if json.Unmarshal(m.Content, &blocks) == nil {
			for _, b := range blocks {
				take(b.CacheControl)
			}
		}
	}
	return ttl
}

func renderedCacheBlock(b aBlock) bool {
	switch b.Type {
	case "text":
		return b.Text != ""
	case "thinking":
		return b.Thinking != ""
	case "redacted_thinking":
		return false
	case "image", "video":
		return b.Source != nil && (b.Source.Data != "" || b.Source.URL != "")
	}
	return true
}

func cacheMark(ttl string) map[string]string {
	return map[string]string{"type": "ephemeral", "ttl": ttl}
}

func partMark(ttl string) map[string]string {
	if ttl == "" {
		return nil
	}
	return cacheMark(ttl)
}

func readClientCache(a aRequest) (*clientCache, error) {
	c := &clientCache{}
	floor := ""
	mark := func(raw json.RawMessage, path string) (string, error) {
		if len(raw) == 0 || string(raw) == "null" {
			return "", nil
		}
		var cc map[string]string
		if json.Unmarshal(raw, &cc) != nil || cc["type"] != "ephemeral" || (cc["ttl"] != "" && cc["ttl"] != "5m" && cc["ttl"] != "1h") {
			return "", fmt.Errorf("cache_control must have type ephemeral and ttl 5m or 1h")
		}
		ttl := cacheTTL(cc)
		c.count++
		if floor == "5m" && ttl == "1h" {
			return "", fmt.Errorf("%s.ttl: a ttl='1h' cache_control block must not come after a ttl='5m' cache_control block. Note that blocks are processed in the following order: `tools`, `system`, `messages`.", path)
		}
		floor = ttl
		return ttl, nil
	}
	for i, t := range a.Tools {
		if ttl, err := mark(t.CacheControl, fmt.Sprintf("tools.%d.cache_control", i)); err != nil {
			return nil, err
		} else if ttl != "" {
			c.tools++
		}
	}
	var system []json.RawMessage
	_ = json.Unmarshal(a.System, &system)
	cut := len(stringOrText(a.System)) - len(withoutBillingHeader(stringOrText(a.System)))
	lastEnd := cut
	for i, raw := range system {
		var b struct {
			CacheControl json.RawMessage `json:"cache_control"`
		}
		_ = json.Unmarshal(raw, &b)
		ttl, err := mark(b.CacheControl, fmt.Sprintf("system.%d.cache_control", i))
		if err != nil {
			return nil, err
		}
		if ttl != "" {
			c.systemMarks++
			prefix, _ := json.Marshal(system[:i+1])
			end := len(stringOrText(prefix))
			if end <= lastEnd {
				c.droppedSystem++
			} else {
				c.system = append(c.system, cachePoint{end, ttl})
				lastEnd = end
			}
		}
	}
	for i, m := range a.Messages {
		var blocks []struct {
			CacheControl json.RawMessage `json:"cache_control"`
		}
		_ = json.Unmarshal(m.Content, &blocks)
		for j, b := range blocks {
			ttl, err := mark(b.CacheControl, fmt.Sprintf("messages.%d.content.%d.cache_control", i, j))
			if err != nil {
				return nil, err
			}
			if ttl == "" {
				continue
			}
			if i == len(a.Messages)-1 && j == len(blocks)-1 {
				c.tail = ttl
			} else {
				c.messages++
			}
		}
	}
	if len(a.CacheControl) > 0 && string(a.CacheControl) != "null" {

		var cc map[string]string
		_ = json.Unmarshal(a.CacheControl, &cc)
		if c.tail != "" && cacheTTL(cc) != c.tail {
			return nil, fmt.Errorf("automatic cache_control and the last block must have the same ttl")
		}
		ttl, err := mark(a.CacheControl, "cache_control")
		if err != nil {
			return nil, err
		}
		c.tail = ttl
	}
	if c.count > 4 {
		return nil, fmt.Errorf("A maximum of 4 blocks with cache_control may be provided. Found %d.", c.count)
	}
	return c, nil
}

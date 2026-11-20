package gateway

import (
	"encoding/json"

	"strings"

	"github.com/tidwall/gjson"
)

const advisorTool = "advisor"

func adviceOf(raw json.RawMessage) (string, bool) {
	c := gjson.ParseBytes(raw)
	switch c.Get("type").String() {
	case "advisor_result":
		return c.Get("text").String(), false
	case "advisor_redacted_result":
		return "The advice is not readable here.", false
	}
	code := c.Get("error_code").String()
	if code == "" {
		code = "unavailable"
	}
	return "The advisor failed: " + code, true
}

func adviceBlock(id, text, code string) map[string]any {
	content := map[string]any{"type": "advisor_result", "text": text}
	if code != "" {
		content = map[string]any{"type": "advisor_tool_result_error", "error_code": code}
	}
	return map[string]any{"type": "advisor_tool_result", "tool_use_id": id, "content": content}
}

func adviceInID(id string) string { return anthropicInID(strings.TrimPrefix(id, "srvtoolu_")) }

func adviceApart(m Message) []Message {
	called, answered := map[string]bool{}, map[string]bool{}
	for _, p := range m.Parts {
		switch {
		case p.Kind == ToolCall && p.Name == advisorTool:
			called[p.ID] = true
		case p.Kind == ToolResult:
			answered[p.CallID] = true
		}
	}
	if len(called) == 0 && len(answered) == 0 {
		return []Message{m}
	}
	var out []Message
	var said, results []Part
	flush := func() {
		if len(said) > 0 {
			out = append(out, Message{Role: "assistant", Parts: said})
			said = nil
		}
		if len(results) > 0 {
			out = append(out, Message{Role: "user", Parts: results})
			results = nil
		}
	}
	for _, p := range m.Parts {
		switch {
		case p.Kind == ToolCall && p.Name == advisorTool:
			if !answered[p.ID] {
				continue
			}
		case p.Kind == ToolResult:
			if called[p.CallID] {
				results = append(results, p)
			}
			continue
		}
		if len(results) > 0 {
			flush()
		}
		said = append(said, p)
	}
	flush()
	if len(out) == 0 {
		return []Message{{Role: "assistant"}}
	}
	return out
}

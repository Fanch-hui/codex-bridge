package gateway

import (
	"encoding/json"
	"strings"
)

func reasoningWithText(item map[string]any) bool {
	if t, _ := item["type"].(string); t != "reasoning" {
		return false
	}
	parts, _ := item["content"].([]any)
	return len(parts) > 0
}

func magpieMadeReasoning(item map[string]any) map[string]any {
	if !reasoningWithText(item) {
		return nil
	}

	text := func(key, typ string) string {
		var b strings.Builder
		parts, _ := item[key].([]any)
		for _, p := range parts {
			pm, _ := p.(map[string]any)
			if pm == nil {
				continue
			}
			if t, _ := pm["type"].(string); typ != "" && t != typ {
				continue
			}
			s, _ := pm["text"].(string)
			b.WriteString(s)
		}
		return b.String()
	}
	said := text("content", "reasoning_text")
	if said == "" {
		said = text("summary", "")
	}
	id, _ := item["id"].(string)
	if id == "" {
		id = "rs_" + newID()
	}
	return map[string]any{"id": id, "type": "reasoning", "status": "completed",
		"summary": []map[string]any{{"type": "summary_text", "text": said}}}
}

func magpieMadeReasoningRaw(raw json.RawMessage, id string) json.RawMessage {
	var it map[string]any
	if decodeJSON(raw, &it) != nil {
		return raw
	}
	made := magpieMadeReasoning(it)
	if made == nil {
		return raw
	}
	if id != "" {
		made["id"] = id
	}
	b, err := json.Marshal(made)
	if err != nil {
		return raw
	}
	return b
}

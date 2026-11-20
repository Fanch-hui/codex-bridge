package gateway

import (
	"bytes"

	"encoding/json"

	"strings"
)

func partsText(raw json.RawMessage) (text, think string, ok bool) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || raw[0] != '[' {
		return "", "", false
	}
	var parts []struct {
		Type     string          `json:"type"`
		Text     string          `json:"text"`
		Thinking json.RawMessage `json:"thinking"`
	}
	if decodeJSON(raw, &parts) != nil {
		return "", "", false
	}
	var tb, kb strings.Builder
	for _, p := range parts {
		switch p.Type {
		case "text":
			tb.WriteString(p.Text)
		case "thinking":

			var s string
			if decodeJSON(p.Thinking, &s) == nil {
				kb.WriteString(s)
				continue
			}
			var inner []struct {
				Text string `json:"text"`
			}
			decodeJSON(p.Thinking, &inner)
			for _, in := range inner {
				kb.WriteString(in.Text)
			}
		}
	}
	return tb.String(), kb.String(), true
}

var messageReasoning = []string{"reasoning_content", "reasoning", "reasoning_details"}

func reasoningText(m map[string]json.RawMessage) string {
	for _, f := range messageReasoning[:2] {
		var s string
		if decodeJSON(m[f], &s) == nil && s != "" {
			return s
		}
	}
	var details []struct {
		Text    string `json:"text"`
		Summary string `json:"summary"`
	}
	decodeJSON(m["reasoning_details"], &details)
	var b strings.Builder
	for _, d := range details {
		if d.Text != "" {
			b.WriteString(d.Text)
		} else {
			b.WriteString(d.Summary)
		}
	}
	return b.String()
}

const noReasoning = " "

func jsonStringIs(q []byte, s string) bool {
	if len(q) == len(s)+2 && q[0] == '"' && string(q[1:len(q)-1]) == s {
		return true
	}
	if len(q) == 0 || q[0] != '"' || bytes.IndexByte(q, '\\') < 0 {
		return false
	}
	u, ok := unquoteJSON(q)
	return ok && u == s
}

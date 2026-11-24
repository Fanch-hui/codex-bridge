package gateway

import (
	"encoding/json"
	"strings"

	"codexbridge/modelprotocol/internal/claudeseal"
)

const codexReasoningMark = "bridge-codex1:"

func validReasoningScope(scope string) bool {
	return scope != "" && strings.IndexFunc(scope, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-')
	}) == -1
}

func scopeClaudeReasoning(value, scope string) string {
	if scope == "" {
		return value
	}
	return codexReasoningMark + scope + ":" + value
}

func claudeThinking(text, signature string) string {
	b, _ := json.Marshal(struct {
		Type      string `json:"type"`
		Thinking  string `json:"thinking"`
		Signature string `json:"signature"`
	}{"thinking", text, signature})
	return claudeseal.Seal(b)
}

func claudePart(block json.RawMessage, summary Part) Part {
	var b struct {
		Type      string `json:"type"`
		Thinking  string `json:"thinking"`
		Signature string `json:"signature"`
		Data      string `json:"data"`
	}
	if block == nil || decodeJSON(block, &b) != nil {
		return summary
	}
	switch {
	case b.Type == "thinking" && b.Signature != "":
		return Part{Kind: Thinking, Text: b.Thinking, Signature: b.Signature, SignedBy: sealAnthropic}
	case b.Type == "redacted_thinking" && b.Data != "":
		return Part{Kind: Thinking, Sealed: block, SealedBy: sealAnthropic}
	}
	return summary
}

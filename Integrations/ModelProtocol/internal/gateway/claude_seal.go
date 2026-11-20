package gateway

import (
	"encoding/json"

	"codexbridge/modelprotocol/internal/claudeseal"
)

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

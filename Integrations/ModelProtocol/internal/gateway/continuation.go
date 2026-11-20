package gateway

import (
	"encoding/json"

	"net"

	"strings"

	"codexbridge/modelprotocol/internal/provider"
)

func geminiEnds(data []byte) bool {
	if !bodyHas(data, `"finishReason"`) && bodyHas(data, `"candidates"`) {
		return false
	}
	type chunk struct {
		Candidates []struct {
			FinishReason string `json:"finishReason"`
		} `json:"candidates"`
	}
	var ch struct {
		chunk
		Response *chunk `json:"response"`
	}
	if json.Unmarshal(data, &ch) != nil {
		return false
	}
	c := ch.chunk
	if ch.Response != nil {
		c = *ch.Response
	}
	if len(c.Candidates) == 0 {
		return true
	}
	for _, cand := range c.Candidates {
		if cand.FinishReason != "" {
			return true
		}
	}
	return false
}

func geminiKin(actual provider.Protocol) bool {
	return actual == provider.Gemini || actual == provider.CodeAssist
}

func chatPrefill(host, model string) string {
	h := strings.ToLower(host)
	switch {
	case h == "api.deepseek.com" || strings.HasSuffix(h, ".deepseek.com"):
		return "prefix"
	case strings.Contains(h, "moonshot") || strings.Contains(h, "kimi"):
		return "partial"
	}
	if s, _, err := net.SplitHostPort(h); err == nil {
		h = s
	}
	h = strings.Trim(h, "[]")
	if h != "localhost" && !strings.HasSuffix(h, ".local") {
		if ip := net.ParseIP(h); ip == nil || !ip.IsLoopback() && !ip.IsPrivate() {
			return ""
		}
	}
	switch m := strings.ToLower(model); {
	case strings.Contains(m, "deepseek"):
		return "prefix"
	case strings.Contains(m, "kimi"):
		return "partial"
	}
	return ""
}

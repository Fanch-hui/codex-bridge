package provider

import (
	"codexbridge/modelprotocol/internal/redact"
)

const quotedReplyMax = 64 << 10

func QuotedReply(raw []byte) string {
	if len(raw) > quotedReplyMax {
		return redact.Scrub(string(raw[:quotedReplyMax]))
	}
	return string(redact.ScrubJSON(raw))
}

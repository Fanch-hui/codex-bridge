// Package claudeseal carries Claude's signed reasoning through a Responses
// client (mysterious_dove_96933 on Discord).
//
// Claude signs each thinking block and seals a redacted_thinking block
// whole, and Anthropic wants both back as they came on the next request
// of a tool loop. A Responses client such as Codex, with store off, keeps
// only what a reply's reasoning items carry, and of those only
// encrypted_content is opaque. So the gateway writes the block there: Mark
// and the block's JSON in base64, which only the gateway reads. Sent
// to OpenAI it would be refused as invalid_encrypted_content, so the
// gateway drops it before any Responses upstream, and a rollout is made
// portable by dropping it there (sessions.PortCodexRollouts).
package claudeseal

import (
	"encoding/base64"
	"encoding/json"
	"strings"
)

// Mark begins the encrypted_content of a reasoning item carrying a
// Claude block.
const Mark = "bridge-claude1:"

// legacyMark began blocks sealed by earlier releases; clients may still
// replay them from stored conversations, so they stay readable.
const legacyMark = "magpie-claude1:"

func cutMark(encrypted string) (string, bool) {
	if rest, ok := strings.CutPrefix(encrypted, Mark); ok {
		return rest, true
	}
	return strings.CutPrefix(encrypted, legacyMark)
}

// Seal is the encrypted_content carrying block, a Messages content block
// (thinking with its signature, or redacted_thinking).
func Seal(block []byte) string {
	return Mark + base64.StdEncoding.EncodeToString(block)
}

// Open is the block an encrypted_content carries: ours is false for one
// the gateway didn't seal, and block nil for one of its own that can't be
// read.
func Open(encrypted string) (block json.RawMessage, ours bool) {
	b64, ok := cutMark(encrypted)
	if !ok {
		return nil, false
	}
	b, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || !json.Valid(b) {
		return nil, true
	}
	return b, true
}

// Is reports whether encrypted is one the gateway sealed.
func Is(encrypted string) bool {
	_, ok := cutMark(encrypted)
	return ok
}

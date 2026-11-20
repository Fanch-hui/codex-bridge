package gateway

import (
	"encoding/base64"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
)

const (
	sigMark = "__ts"
	sigRaw  = "r"
	sigKept = "k"
	sigEnd  = "__"
)

func signedID(id, sig string) string {
	if sig == "" {
		return id
	}
	if id == "" {
		id = "call_" + newID()
	}
	if key := keepSignature(sig); key != "" {
		return id + sigMark + sigKept + strconv.Itoa(len(key)) + sigEnd + key
	}
	kind, enc := sigRaw, base64.RawURLEncoding.EncodeToString([]byte(sig))
	if b, err := base64.StdEncoding.DecodeString(sig); err == nil && base64.StdEncoding.EncodeToString(b) == sig {
		kind, enc = "", base64.RawURLEncoding.EncodeToString(b)
	}
	return id + sigMark + kind + strconv.Itoa(len(enc)) + sigEnd + enc
}

func unsignedID(id string) (string, string) {
	for at := 1; at < len(id); {
		i := strings.Index(id[at:], sigMark)
		if i < 0 {
			break
		}
		i += at
		at = i + 1
		rest := id[i+len(sigMark):]
		raw := strings.HasPrefix(rest, sigRaw)
		if raw {
			rest = rest[len(sigRaw):]
		}
		kept := !raw && strings.HasPrefix(rest, sigKept)
		if kept {
			rest = rest[len(sigKept):]
		}
		d := 0
		for d < len(rest) && rest[d] >= '0' && rest[d] <= '9' {
			d++
		}
		enc, ok := strings.CutPrefix(rest[d:], sigEnd)
		if !ok {
			continue
		}
		if kept && d == 0 {
			continue
		}

		if d > 0 && rest[:d] != strconv.Itoa(len(enc)) {
			return id, ""
		}
		if kept {
			if sig := keptSignature(enc); sig != "" {
				return id[:i], sig
			}
			return id, ""
		}
		b, err := base64.RawURLEncoding.DecodeString(enc)
		if err != nil || len(b) == 0 {
			return id, ""
		}
		if raw {
			return id[:i], string(b)
		}
		return id[:i], base64.StdEncoding.EncodeToString(b)
	}
	return id, ""
}

func unsignCalls(r *Request) {
	for i, m := range r.Messages {
		var parts []Part
		for j, p := range m.Parts {
			switch p.Kind {
			case ToolCall:
				id, sig := unsignedID(p.ID)
				if sig == "" {
					continue
				}
				p.ID = id
				if p.Signature == "" {
					p.Signature = sig
				}
			case ToolResult:
				id, sig := unsignedID(p.CallID)
				if sig == "" {
					continue
				}
				p.CallID = id
			default:
				continue
			}
			if parts == nil {
				parts = slices.Clone(m.Parts)
			}
			parts[j] = p
		}
		if parts != nil {
			r.Messages[i].Parts = parts
		}
	}
}

func googleSignature(extra json.RawMessage) string {
	if len(extra) == 0 {
		return ""
	}
	var v struct {
		Google struct {
			ThoughtSignature string `json:"thought_signature"`
		} `json:"google"`
	}
	json.Unmarshal(extra, &v)
	return v.Google.ThoughtSignature
}

func googleExtra(sig string) map[string]any {
	return map[string]any{"google": map[string]any{"thought_signature": sig}}
}

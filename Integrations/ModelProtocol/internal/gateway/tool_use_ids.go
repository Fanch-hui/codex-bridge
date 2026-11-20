package gateway

import (
	"bytes"
	"encoding/base64"

	"strings"
	"unicode/utf8"
)

func unsaltCallID(id string) (string, bool) {
	if !strings.HasPrefix(id, anthropicIDMark) || !safeIDChars.MatchString(id) {
		return "", false
	}
	raw, err := base64.RawURLEncoding.DecodeString(id[len(anthropicIDMark):])
	if err != nil || !utf8.Valid(raw) {
		return "", false
	}
	at := bytes.IndexByte(raw, 0)
	if at <= 0 || at == len(raw)-1 {
		return "", false
	}
	return string(raw[:at]), true
}

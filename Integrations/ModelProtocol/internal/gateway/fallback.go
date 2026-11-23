package gateway

import (
	"encoding/json"

	"net/http"

	"strconv"
	"strings"

	"codexbridge/modelprotocol/internal/lazyre"
)

const refusedStatus = http.StatusBadRequest

var filterReasons = map[string]string{
	"refusal":                  "refusal",
	"content_filter":           "content_filter",
	"content_policy_violation": "content_filter",

	"content_policy_rejected": "content_policy_rejected",

	"censorship_blocked": "censorship_blocked",

	"sensitive":              "sensitive",
	"data_inspection_failed": "data_inspection_failed",
	"DataInspectionFailed":   "data_inspection_failed",
	"SAFETY":                 "safety",
	"PROHIBITED_CONTENT":     "safety",
	"BLOCKLIST":              "safety",
	"SPII":                   "safety",
	"IMAGE_SAFETY":           "safety",
}

func refusedNote(reason string) string {
	return "safety filter: " + reason
}

func errorCode(raw json.RawMessage) string {
	var e struct {
		Code any    `json:"code"`
		Type string `json:"type"`
	}
	if json.Unmarshal(raw, &e) != nil {
		return ""
	}
	if c, ok := e.Code.(string); ok && c != "" {
		return c
	}
	return e.Type
}

var policyCode = lazyre.New(`^[a-z]+_policy$`)

var sensitiveCode = lazyre.New(`SensitiveContentDetected$`)

var flaggedWords = lazyre.New(`(?i)flagged|usage polic`)

func policyRefusal(raw []byte) (string, bool) {
	var e struct {
		Code    any    `json:"code"`
		Type    string `json:"type"`
		Message string `json:"message"`
		Error   *struct {
			Code    any    `json:"code"`
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(raw, &e) != nil {
		return "", false
	}
	code, typ, msg := e.Code, e.Type, e.Message
	if e.Error != nil {
		code, typ, msg = e.Error.Code, e.Error.Type, e.Error.Message
	}
	c, _ := code.(string)
	if c == "" {
		c = typ
	}
	note := func(reason string) (string, bool) {
		if msg = strings.TrimSpace(msg); msg != "" {

			if len(msg) > 1000 {
				msg = msg[:1000] + "…"
			}
			return refusedNote(reason) + " — " + msg, true
		}
		return refusedNote(reason), true
	}
	switch r, ok := filterReasons[c]; {
	case ok:
		return note(r)
	case policyCode.MatchString(c), sensitiveCode.MatchString(c):
		return note(c)
	case c == "1301" && strings.Contains(msg, "敏感"):

		return note("sensitive")
	case c == "invalid_prompt" && flaggedWords.MatchString(msg):
		return note(c)
	case strings.TrimSpace(msg) == highRiskRefusal:
		return note("high risk")
	}
	return "", false
}

const highRiskRefusal = "The request was rejected because it was considered high risk"

func filterRefused(data string) (string, int, json.RawMessage) {
	code := refusedCode(data)
	if code == "" {
		return "", 0, nil
	}
	said := code
	c, _ := json.Marshal(map[string]string{"code": code})
	if _, ok := policyRefusal(c); !ok {
		said = "content_filter"
	}
	b, _ := json.Marshal(map[string]any{"error": map[string]string{"type": "invalid_request_error", "code": said}})
	return code, refusedStatus, b
}

func refusedCode(data string) string {
	var v struct {
		Error    json.RawMessage `json:"error"`
		Response struct {
			Error json.RawMessage `json:"error"`
		} `json:"response"`
	}
	if json.Unmarshal([]byte(data), &v) != nil {
		return ""
	}
	for _, raw := range []json.RawMessage{v.Response.Error, v.Error, json.RawMessage(data)} {
		if len(raw) == 0 || string(raw) == "null" {
			continue
		}
		if _, ok := policyRefusal(raw); ok {
			if c := errorCode(raw); c != "" && c != "error" {
				return c
			}
			return "content_filter"
		}
	}
	return ""
}

func namedStatusOf(errRaw []byte) int {
	if !carries(errRaw) {
		return 0
	}
	var e struct {
		Code    json.RawMessage `json:"code"`
		Status  json.RawMessage `json:"status"`
		Message json.RawMessage `json:"message"`
	}
	var msg string
	if json.Unmarshal(errRaw, &msg) != nil {
		if json.Unmarshal(errRaw, &e) != nil {
			return 0
		}
		json.Unmarshal(e.Message, &msg)
	}
	if gatewaySaid(msg) || tooLong(http.StatusBadRequest, msg) {
		return 0
	}
	num := func(raw json.RawMessage) int {

		var n json.Number
		if len(raw) == 0 || raw[0] < '0' || raw[0] > '9' || json.Unmarshal(raw, &n) != nil {
			return 0
		}
		if i, err := n.Int64(); err == nil && i >= 400 && i < 600 {
			return int(i)
		}
		return 0
	}
	for _, raw := range []json.RawMessage{e.Status, e.Code} {
		if n := num(raw); n != 0 {
			return n
		}
	}
	return textStatus(msg)
}

var httpSaid = lazyre.New(`[(（]\s*HTTP\s*(429|5\d\d)\s*[)）]`)

func textStatus(msg string) int {
	if gatewaySaid(msg) || tooLong(http.StatusBadRequest, msg) {
		return 0
	}
	m := httpSaid.FindStringSubmatch(msg)
	if m == nil {
		return 0
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

func gatewaySaid(msg string) bool {
	return strings.Contains(msg, loopGuardSaid) || strings.Contains(msg, emptyReply) || strings.Contains(msg, reloopedError)
}

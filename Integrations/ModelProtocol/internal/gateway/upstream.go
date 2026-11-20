package gateway

import (
	"bytes"
	"cmp"
	"encoding/json"
	"strings"

	"codexbridge/modelprotocol/internal/provider"
)

func upstreamStop(b []byte) string {
	if !bodyHas(b, `stop_reason"`) && !bodyHas(b, `finish_reason"`) && !bodyHas(b, `"response.`) {
		return ""
	}
	var v struct {
		Type       string `json:"type"`
		StopReason string `json:"stop_reason"`
		Delta      struct {
			StopReason string `json:"stop_reason"`
		} `json:"delta"`
		Choices []struct {
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
		Response struct {
			Status            string `json:"status"`
			IncompleteDetails *struct {
				Reason string `json:"reason"`
			} `json:"incomplete_details"`
		} `json:"response"`
	}
	if json.Unmarshal(b, &v) != nil {
		return ""
	}
	switch {
	case v.Delta.StopReason != "":
		return v.Delta.StopReason
	case v.StopReason != "":
		return v.StopReason
	case strings.HasPrefix(v.Type, "response.") && v.Response.Status != "" && v.Response.Status != "in_progress" && v.Response.Status != "queued":
		if d := v.Response.IncompleteDetails; d != nil && d.Reason != "" {
			return v.Response.Status + ": " + d.Reason
		}
		return v.Response.Status
	}
	for _, c := range v.Choices {
		if c.FinishReason != "" {
			return c.FinishReason
		}
	}
	return ""
}

func replyEnds(proto provider.Protocol, data, stop string) bool {
	switch {
	case proto == provider.Anthropic:
		t := eventType(data)
		return t == "message_stop" || t == "error" || t == "message_delta" && stop != ""
	case proto == provider.Responses:
		t := eventType(data)
		return t == "error" || strings.HasPrefix(t, "response.") && (lastEvent(t) || stop != "")
	case geminiKin(proto):
		return stop != "" || geminiEnds([]byte(data))
	}
	return stop != ""
}

func eventType(data string) string {
	var v struct {
		Type json.RawMessage `json:"type"`
	}
	var t string
	if json.Unmarshal([]byte(data), &v) != nil || json.Unmarshal(v.Type, &t) != nil {
		return ""
	}
	return t
}

func carriedError(data string) (ev Event, ok bool) {
	var v struct {
		Type     json.RawMessage `json:"type"`
		Error    json.RawMessage `json:"error"`
		Response json.RawMessage `json:"response"`
	}
	if json.Unmarshal([]byte(data), &v) != nil {
		return Event{}, false
	}
	var t string
	json.Unmarshal(v.Type, &t)
	var r struct {
		Error json.RawMessage `json:"error"`
	}
	json.Unmarshal(v.Response, &r)
	if t != "error" && t != "response.failed" && !carries(v.Error) && !carries(r.Error) {
		return Event{}, false
	}
	code, status, said := filterRefused(data)
	if status == 0 {

		status = cmp.Or(namedStatusOf(r.Error), namedStatusOf(v.Error))
	}
	return Event{Kind: KError, Text: streamErrorText(data, r.Error, v.Error), Code: code, Status: status, Said: said}, true
}

func streamErrorText(data string, errs ...json.RawMessage) string {
	for _, raw := range errs {
		if !carries(raw) {
			continue
		}
		var s string
		if json.Unmarshal(raw, &s) == nil {
			if s = strings.TrimSpace(s); s != "" {
				return s
			}
			continue
		}
		var e struct {
			Message string `json:"message"`
			Type    string `json:"type"`
		}
		if json.Unmarshal(raw, &e) == nil {
			if m := strings.TrimSpace(e.Message); m != "" {
				return m
			}
			if e.Type != "" {
				return e.Type
			}
		}
	}
	return provider.APIError([]byte(data), "the upstream reported an error")
}

func carries(raw json.RawMessage) bool {
	s := bytes.TrimSpace(raw)
	return len(s) > 0 && string(s) != "null"
}

package gateway

import (
	"encoding/json"

	"github.com/tidwall/gjson"
)

func liftMessageTools(body []byte) []byte {
	if !bodyHas(body, `"tools"`) {
		return body
	}
	if len(gjson.GetBytes(body, "messages.#.tools").Array()) == 0 {
		return body
	}
	var v struct {
		Messages []json.RawMessage `json:"messages"`
		Tools    []json.RawMessage `json:"tools"`
	}
	if json.Unmarshal(body, &v) != nil {
		return body
	}
	have := map[string]bool{}
	for _, t := range v.Tools {
		have[chatToolKey(gjson.ParseBytes(t))] = true
	}
	tools := v.Tools
	msgs := make([]json.RawMessage, 0, len(v.Messages))
	for _, raw := range v.Messages {
		m := gjson.ParseBytes(raw)
		more := m.Get("tools")
		if !more.Exists() {
			msgs = append(msgs, raw)
			continue
		}
		for _, t := range more.Array() {
			if !t.IsObject() {
				continue
			}
			if k := chatToolKey(t); !have[k] {
				have[k] = true
				tools = append(tools, json.RawMessage(t.Raw))
			}
		}
		role := m.Get("role").String()
		if (role == "system" || role == "developer") && emptyContent(m.Get("content")) {
			continue
		}
		var mm map[string]json.RawMessage
		if json.Unmarshal(raw, &mm) != nil {
			msgs = append(msgs, raw)
			continue
		}
		delete(mm, "tools")
		out, err := marshalPlain(mm)
		if err != nil {
			return body
		}
		msgs = append(msgs, out)
	}
	fields := map[string]any{"messages": msgs}
	if len(tools) > 0 {
		fields["tools"] = tools
	}
	return withFields(body, fields)
}

func chatToolKey(t gjson.Result) string {
	if n := t.Get("function.name").String(); n != "" {
		return n
	}
	if n := t.Get("name").String(); n != "" {
		return n
	}
	return "#" + t.Get("type").String()
}

package gateway

import (
	"encoding/json"

	"github.com/tidwall/gjson"
)

func shapeChatTools(body []byte) []byte {
	if !bodyHas(body, `"tools"`) {
		return body
	}
	tools := gjson.GetBytes(body, "tools")
	if !tools.IsArray() {
		return body
	}
	need := false
	for _, t := range tools.Array() {
		if unshapedChatTool(t) {
			need = true
			break
		}
	}
	if !need {
		return body
	}
	var raw []json.RawMessage
	if json.Unmarshal([]byte(tools.Raw), &raw) != nil {
		return body
	}
	for i, t := range raw {
		if !unshapedChatTool(gjson.ParseBytes(t)) {
			continue
		}
		var m map[string]json.RawMessage
		if json.Unmarshal(t, &m) != nil {
			continue
		}
		fn := map[string]json.RawMessage{}
		for _, k := range []string{"name", "description", "strict"} {
			if v, ok := m[k]; ok {
				fn[k] = v
				delete(m, k)
			}
		}
		for _, k := range []string{"parameters", "inputSchema", "input_schema"} {
			if v, ok := m[k]; ok {
				if _, set := fn["parameters"]; !set {
					fn["parameters"] = v
				}
				delete(m, k)
			}
		}
		f, err := marshalPlain(fn)
		if err != nil {
			continue
		}
		m["type"] = json.RawMessage(`"function"`)
		m["function"] = f
		out, err := marshalPlain(m)
		if err != nil {
			continue
		}
		raw[i] = out
	}
	return withFields(body, map[string]any{"tools": raw})
}

func unshapedChatTool(t gjson.Result) bool {
	if !t.IsObject() || t.Get("function").Exists() {
		return false
	}
	if typ := t.Get("type").String(); typ != "" && typ != "function" {
		return false
	}
	n := t.Get("name")
	return n.Type == gjson.String && n.String() != ""
}

package gateway

import (
	"bytes"
	"encoding/json"
)

const liteNamespace = "functions"

func liftAdditionalTools(body []byte) []byte {
	if !bodyHas(body, `"additional_tools"`) {
		return body
	}
	in, found, ok := topMember(body, "input")
	if !ok || !found || len(in) == 0 || in[0] != '[' {
		return body
	}
	var tools []any
	if raw, has, _ := topMember(body, "tools"); has {
		if t, ok := decodeAny(raw).([]any); ok {
			tools = t
		}
	}
	have := toolsByName(tools)
	var kept [][]byte
	lifted, bad := false, false
	eachElement(in, func(it []byte) bool {
		if ty, ok := stringBytes(memberOrNil(it, "type")); !ok || string(ty) != "additional_tools" {

			if ns, ok := stringBytes(memberOrNil(it, "namespace")); ok && string(ns) == liteNamespace {
				it = withoutTopMember(it, "namespace")
			}
			kept = append(kept, it)
			return true
		}
		im, _ := decodeAny(it).(map[string]any)
		if im == nil {
			bad = true
			return false
		}
		lifted = true
		more, _ := im["tools"].([]any)
		for _, t := range more {
			tm, _ := t.(map[string]any)
			if tm == nil {
				continue
			}
			if tm["type"] == "namespace" && tm["name"] == liteNamespace {
				nested, _ := tm["tools"].([]any)
				for _, n := range nested {
					if nm, _ := n.(map[string]any); nm != nil {
						tools = addTool(tools, have, nm)
					}
				}
				continue
			}
			tools = addTool(tools, have, tm)
		}
		return true
	})
	if !lifted || bad {
		return body
	}
	var toolsJSON []byte
	if len(tools) > 0 {
		t, err := marshalPlain(tools)
		if err != nil {
			return body
		}
		toolsJSON = t
	}

	raw := trimJSON(body)
	out := make([]byte, 0, len(raw)+len(toolsJSON)+len(`,"tools":`))
	last, hadTools := 0, false
	eachMemberAt(raw, func(k0, k1, v0, v1 int) bool {
		switch key := raw[k0:k1]; {
		case keyIs(key, "input"):
			out = append(append(out, raw[last:v0]...), '[')
			for i, it := range kept {
				if i > 0 {
					out = append(out, ',')
				}
				out = append(out, it...)
			}
			out = append(out, ']')
			last = v1
		case keyIs(key, "tools"):
			hadTools = true
			if toolsJSON != nil {
				out = append(append(out, raw[last:v0]...), toolsJSON...)
				last = v1
			}
		}
		return true
	})
	out = append(out, raw[last:len(raw)-1]...)
	if toolsJSON != nil && !hadTools {
		out = append(append(out, `,"tools":`...), toolsJSON...)
	}
	return append(out, '}')
}

func decodeAny(raw []byte) any {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if dec.Decode(&v) != nil {
		return nil
	}
	return v
}

func toolsByName(tools []any) map[string]map[string]any {
	have := map[string]map[string]any{}
	for _, t := range tools {
		if tm, _ := t.(map[string]any); tm != nil {
			have[toolKey(tm)] = tm
		}
	}
	return have
}

func toolKey(tm map[string]any) string {
	if n, _ := tm["name"].(string); n != "" {
		return n
	}
	ty, _ := tm["type"].(string)
	return "#" + ty
}

func addTool(tools []any, have map[string]map[string]any, tm map[string]any) []any {
	k := toolKey(tm)
	old := have[k]
	if old == nil {
		have[k] = tm
		return append(tools, tm)
	}
	if old["type"] != "namespace" || tm["type"] != "namespace" {
		return tools
	}
	nested, _ := old["tools"].([]any)
	more, _ := tm["tools"].([]any)
	for _, nt := range more {
		nm, _ := nt.(map[string]any)
		if nm != nil && !containsNamed(nested, nm["name"]) {
			nested = append(nested, nm)
		}
	}
	old["tools"] = nested
	return tools
}

func containsNamed(tools []any, name any) bool {
	for _, o := range tools {
		if om, _ := o.(map[string]any); om["name"] == name {
			return true
		}
	}
	return false
}

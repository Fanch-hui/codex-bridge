package gateway

import (
	"encoding/json"

	"github.com/tidwall/gjson"
)

func emptyContent(c gjson.Result) bool {
	switch {
	case !c.Exists() || c.Type == gjson.Null:
		return true
	case c.Type == gjson.String:
		return c.String() == ""
	case c.IsArray():
		empty := true
		c.ForEach(func(_, b gjson.Result) bool {
			empty = b.Get("type").String() == "text" && b.Get("text").String() == ""
			return empty
		})
		return empty
	}
	return false
}

func toolLoadedText(name string) string {
	return "Tool " + name + " is loaded and can be called now."
}

func toolRefs(content json.RawMessage) []string {
	if !bodyHas(content, `"tool_reference"`) {
		return nil
	}
	var names []string
	gjson.ParseBytes(content).ForEach(func(_, b gjson.Result) bool {
		if n := b.Get("tool_name").String(); b.Get("type").String() == "tool_reference" && n != "" {
			names = append(names, n)
		}
		return true
	})
	return names
}

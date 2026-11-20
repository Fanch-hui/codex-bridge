package gateway

import (
	"encoding/json"

	"maps"
	"slices"
	"strings"
)

func snakeToCamel(s string) string {
	parts := strings.Split(s, "_")
	for i := 1; i < len(parts); i++ {
		if p := parts[i]; p != "" {
			parts[i] = strings.ToUpper(p[:1]) + p[1:]
		}
	}
	return strings.Join(parts, "")
}

var googleSearchTools = map[string]bool{"googleSearch": true, "googleSearchRetrieval": true}

var googleToolNames = map[string]bool{"urlContext": true, "codeExecution": true, "googleMaps": true,
	"fileSearch": true, "enterpriseWebSearch": true, "computerUse": true, "retrieval": true}

func googleTools(t map[string]json.RawMessage, known bool) (search bool, kept []json.RawMessage) {

	for _, name := range slices.Sorted(maps.Keys(t)) {
		k, v := snakeToCamel(name), t[name]
		switch {
		case k == "functionDeclarations":
		case googleSearchTools[k]:
			search = true
		case known && !googleToolNames[k]:
		default:
			if len(v) == 0 || string(v) == "null" {
				v = json.RawMessage("{}")
			}
			b, err := json.Marshal(map[string]json.RawMessage{k: v})
			if err == nil {
				kept = append(kept, b)
			}
		}
	}
	return search, kept
}

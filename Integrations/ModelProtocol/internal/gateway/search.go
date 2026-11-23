package gateway

import (
	"encoding/json"

	"slices"
)

func searchTool(tools []Tool) Tool {
	name := "web_search"
	for slices.ContainsFunc(tools, func(t Tool) bool { return t.Name == name }) {
		name = "bridge_" + name
	}
	return Tool{Name: name,
		Description: "Search the web for current information: news, releases, documentation, prices, anything after your training or that you are unsure of. Returns what the pages found say, with their URLs. Cite the URLs you use.",
		Schema:      json.RawMessage(`{"type":"object","properties":{"query":{"type":"string","description":"What to search for"}},"required":["query"]}`)}
}

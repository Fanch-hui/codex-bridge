package gateway

import (
	"codexbridge/modelprotocol/internal/capre"
)

const stubToolDescription = "Called earlier in this conversation; not available now."

var anthropicToolName = capre.MustCompile(`^[a-zA-Z0-9_-]+$`, 128)

func historyCallNames(r *Request) []string {
	var names []string
	seen := map[string]bool{}
	for _, m := range r.Messages {
		for _, p := range m.Parts {
			if p.Kind == ToolCall && !seen[p.Name] && anthropicToolName.MatchString(p.Name) {
				seen[p.Name] = true
				names = append(names, p.Name)
			}
		}
	}
	return names
}

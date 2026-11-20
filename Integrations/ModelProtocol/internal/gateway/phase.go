package gateway

const (
	phaseCommentary = "commentary"
	phaseFinal      = "final_answer"
)

const heldMost = 512

func unphased(it map[string]any) bool {
	if it == nil || it["type"] != "message" {
		return false
	}
	if r, ok := it["role"]; ok && r != "assistant" {
		return false
	}
	p, _ := it["phase"].(string)
	return p == ""
}

func phaseOutput(output []any, done bool) bool {
	last := -1
	for i, it := range output {
		if m, _ := it.(map[string]any); m != nil && m["type"] != "reasoning" {
			last = i
		}
	}
	changed := false
	for i, it := range output {
		m, _ := it.(map[string]any)
		if !unphased(m) {
			continue
		}
		switch {
		case i < last:
			m["phase"] = phaseCommentary
		case i == last && done:
			m["phase"] = phaseFinal
		default:
			continue
		}
		changed = true
	}
	return changed
}

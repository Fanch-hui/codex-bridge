package gateway

const skipSignature = "skip_thought_signature_validator"

func dropSecondAnswers(msgs []Message) []Message {
	var out []Message
	answered := map[string]bool{}
	for i, m := range msgs {
		var parts []Part
		for j, p := range m.Parts {
			switch {
			case p.Kind == ToolCall && p.ID != "":
				delete(answered, p.ID)
			case p.Kind == ToolResult && p.CallID != "" && p.Standalone == nil:
				if answered[p.CallID] {
					if parts == nil {
						parts = append(make([]Part, 0, len(m.Parts)), m.Parts[:j]...)
					}
					if out == nil {
						out = append(make([]Message, 0, len(msgs)), msgs[:i]...)
					}
					continue
				}
				answered[p.CallID] = true
			}
			if parts != nil {
				parts = append(parts, p)
			}
		}
		if out == nil {
			continue
		}
		if parts != nil {
			if len(parts) == 0 {
				continue
			}
			m.Parts = parts
		}
		out = append(out, m)
	}
	if out == nil {
		return msgs
	}
	return out
}

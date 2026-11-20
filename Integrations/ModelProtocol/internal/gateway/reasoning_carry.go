package gateway

import (
	"encoding/json"
	"slices"
	"strconv"

	"codexbridge/modelprotocol/internal/provider"
)

const (
	reasonMark = "__rk"
	reasonEnd  = "__"
)

var reasonKeyLen = len(sigKey(""))

var reasonTail = reasonMark + strconv.Itoa(reasonKeyLen) + reasonEnd

func reasonedID(id string, items []json.RawMessage) string {
	if len(items) == 0 {
		return id
	}
	b, err := json.Marshal(items)
	if err != nil {
		return id
	}
	key := keepSignature(string(b))
	if key == "" {
		return id
	}
	if id == "" {
		id = "call_" + newID()
	}
	return id + reasonTail + key
}

func unreasonedID(id string) (string, []json.RawMessage) {
	at := len(id) - reasonKeyLen - len(reasonTail)
	if at < 1 || id[at:at+len(reasonTail)] != reasonTail {
		return id, nil
	}
	own, key := id[:at], id[at+len(reasonTail):]
	var items []json.RawMessage
	if kept := keptSignature(key); kept != "" {
		if json.Unmarshal([]byte(kept), &items) != nil {
			items = nil
		}
	}
	return own, items
}

func carryReasoning(dec func(string, func(Event)) error, from, actual provider.Protocol) func(string, func(Event)) error {
	if from == provider.Responses || actual != provider.Responses {
		return dec
	}
	var held []json.RawMessage
	return func(data string, emit func(Event)) error {
		return dec(data, func(ev Event) {
			switch {
			case ev.Kind == KSealed && ev.Name == sealResponses && ev.Text != "":
				held = append(held, json.RawMessage(ev.Text))
			case ev.Kind == KToolStart && len(held) > 0:
				ev.ID = reasonedID(ev.ID, held)
				held = nil
			}
			emit(ev)
		})
	}
}

func unreasonCalls(r *Request) {
	for i, m := range r.Messages {
		var parts, lead []Part
		for j, p := range m.Parts {
			var items []json.RawMessage
			switch p.Kind {
			case ToolCall:
				id, its := unreasonedID(p.ID)
				if id == p.ID {
					continue
				}
				p.ID, items = id, its
			case ToolResult:
				id, _ := unreasonedID(p.CallID)
				if id == p.CallID {
					continue
				}
				p.CallID = id
			default:
				continue
			}
			if parts == nil {
				parts = slices.Clone(m.Parts)
			}
			parts[j] = p
			for _, it := range items {
				lead = append(lead, Part{Kind: Thinking, Sealed: it, SealedBy: sealResponses})
			}
		}
		if parts != nil {
			r.Messages[i].Parts = append(lead, parts...)
		}
	}
}

package gateway

import (
	"cmp"
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	"codexbridge/modelprotocol/internal/claudeseal"
	"codexbridge/modelprotocol/internal/provider"
	"github.com/tidwall/gjson"
)

type rItem struct {
	Type    string          `json:"type,omitempty"`
	Role    string          `json:"role,omitempty"`
	Content json.RawMessage `json:"content,omitempty"`

	ID        string          `json:"id,omitempty"`
	CallID    string          `json:"call_id,omitempty"`
	Name      string          `json:"name,omitempty"`
	Namespace string          `json:"namespace,omitempty"`
	Arguments rArgs           `json:"arguments,omitempty"`
	Input     string          `json:"input,omitempty"`
	Output    json.RawMessage `json:"output,omitempty"`
	Status    string          `json:"status,omitempty"`

	Tools []rTool `json:"tools,omitempty"`

	FileData string `json:"file_data,omitempty"`
	FileID   string `json:"file_id,omitempty"`
	Filename string `json:"filename,omitempty"`

	Reasoning *struct {
		Effort string `json:"effort"`
	} `json:"reasoning,omitempty"`

	Summary          []rText `json:"summary,omitempty"`
	EncryptedContent string  `json:"encrypted_content,omitempty"`

	Action *struct {
		Query   string `json:"query"`
		Sources []struct {
			URL string `json:"url"`
		} `json:"sources"`
	} `json:"action,omitempty"`
}

type rArgs string

func (a *rArgs) UnmarshalJSON(b []byte) error {
	var s string
	if decodeJSON(b, &s) == nil {
		*a = rArgs(s)
	} else if string(b) != "null" {
		*a = rArgs(b)
	}
	return nil
}

type rText struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type rTool struct {
	Type        string          `json:"type"`
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	Parameters  json.RawMessage `json:"parameters,omitempty"`
	Strict      *bool           `json:"strict,omitempty"`
	Tools       []rTool         `json:"tools,omitempty"`
	Execution   string          `json:"execution,omitempty"`
	Format      *rFormat        `json:"format,omitempty"`

	ExternalWebAccess json.RawMessage `json:"external_web_access,omitempty"`
}

type rFormat struct {
	Type       string `json:"type"`
	Syntax     string `json:"syntax,omitempty"`
	Definition string `json:"definition,omitempty"`
}

var customSchema = json.RawMessage(`{"type":"object","properties":{"input":{"type":"string","description":"The tool's free-form input, the whole of it, exactly as it is to be run."}},"required":["input"],"additionalProperties":false}`)

func customDescription(t rTool) string {
	d := strings.TrimSpace(t.Description)
	if d != "" {
		d += "\n\n"
	}
	d += "Put the tool's whole free-form input, as it is to be run, in the `input` string; it is passed on as written, so it is not itself JSON."
	if f := t.Format; f != nil && f.Type == "grammar" && strings.TrimSpace(f.Definition) != "" {
		syntax := f.Syntax
		if syntax == "" {
			syntax = "the"
		}
		d += "\n\nThe input follows this " + syntax + " grammar:\n" + strings.TrimSpace(f.Definition)
	}
	return d
}

func customInput(args string) string {
	var a struct {
		Input *string `json:"input"`
	}
	if decodeJSON([]byte(args), &a) == nil && a.Input != nil {
		return *a.Input
	}
	var str string
	if decodeJSON([]byte(args), &str) == nil {
		return str
	}
	return args
}

const toolSearch = "tool_search"

func searchFound(tools []rTool) string {
	var names []string
	for _, t := range tools {
		switch t.Type {
		case "function":
			names = append(names, t.Name)
		case "namespace":
			for _, nt := range t.Tools {
				if nt.Type == "function" {
					names = append(names, flatName(t.Name, nt.Name))
				}
			}
		}
	}
	if len(names) == 0 {
		return "No tools matched the search."
	}
	return "These tools are now available to call: " + strings.Join(names, ", ")
}

func unsealed(schema json.RawMessage) json.RawMessage {
	if !bodyHas(schema, `"encrypted"`) {
		return schema
	}
	var v any
	if decodeJSON(schema, &v) != nil {
		return schema
	}
	var strip func(any)
	strip = func(v any) {
		switch x := v.(type) {
		case map[string]any:
			if _, ok := x["encrypted"].(bool); ok {
				delete(x, "encrypted")
			}
			for _, c := range x {
				strip(c)
			}
		case []any:
			for _, c := range x {
				strip(c)
			}
		}
	}
	strip(v)
	out, err := marshalPlain(v)
	if err != nil {
		return schema
	}
	return out
}

func flatName(namespace, name string) string {
	return provider.FlatName(namespace, name)
}

type rRequest struct {
	Model             string          `json:"model"`
	Instructions      string          `json:"instructions,omitempty"`
	Input             json.RawMessage `json:"input"`
	Tools             []rTool         `json:"tools,omitempty"`
	ToolChoice        json.RawMessage `json:"tool_choice,omitempty"`
	MaxOutputTokens   int             `json:"max_output_tokens,omitempty"`
	Temperature       *float64        `json:"temperature,omitempty"`
	TopP              *float64        `json:"top_p,omitempty"`
	Stream            bool            `json:"stream,omitempty"`
	ParallelToolCalls *bool           `json:"parallel_tool_calls,omitempty"`
	ServiceTier       string          `json:"service_tier,omitempty"`
	PromptCacheKey    string          `json:"prompt_cache_key,omitempty"`

	PromptCacheRetention string          `json:"prompt_cache_retention,omitempty"`
	Include              []string        `json:"include,omitempty"`
	ClientMetadata       json.RawMessage `json:"client_metadata,omitempty"`
	AccessPrograms       json.RawMessage `json:"access_programs,omitempty"`
	Text                 json.RawMessage `json:"text,omitempty"`
	Reasoning            *struct {
		Effort  string `json:"effort,omitempty"`
		Summary string `json:"summary,omitempty"`
	} `json:"reasoning,omitempty"`
}

func textFormat(text json.RawMessage) (json.RawMessage, *Format) {
	var fields map[string]json.RawMessage
	if decodeJSON(text, &fields) != nil {
		return text, nil
	}
	f := openAIFormat(fields["format"])
	if f == nil {
		return text, nil
	}
	delete(fields, "format")
	if len(fields) == 0 {
		return nil, f
	}
	rest, _ := json.Marshal(fields)
	return rest, f
}

func sentRaw(v json.RawMessage) json.RawMessage {
	if t := strings.TrimSpace(string(v)); t == "" || t == "null" {
		return nil
	}
	return v
}

func parseResponses(body []byte) (*Request, error) { return readResponses(body, false) }

func readResponses(body []byte, facts bool) (*Request, error) {
	return readResponsesFor(body, facts, false)
}

func readResponsesFor(body []byte, facts, keepInstructions bool) (*Request, error) {
	decode := decodeJSON
	if facts {
		decode = decodeJSONView
	}

	body = liftAdditionalTools(body)
	var q rRequest
	if err := decode(body, &q); err != nil {
		return nil, fmt.Errorf("invalid request: %v", err)
	}
	r := &Request{Model: q.Model, System: q.Instructions, MaxTokens: q.MaxOutputTokens, Temp: q.Temperature,
		TopP: q.TopP, Stream: q.Stream, Parallel: q.ParallelToolCalls, Fast: q.ServiceTier == "priority" || q.ServiceTier == "ultrafast", Ultrafast: q.ServiceTier == "ultrafast", Tier: q.ServiceTier, CacheKey: q.PromptCacheKey, Include: q.Include,
		ClientMetadata: sentRaw(q.ClientMetadata), AccessPrograms: q.AccessPrograms}
	r.Text, r.Format = textFormat(sentRaw(q.Text))
	if q.Instructions != "" {
		r.systemParts = []string{q.Instructions}
	}

	r.hourMarks = q.PromptCacheRetention != "in_memory"

	r.instructionsKept = keepInstructions
	if q.Reasoning != nil {
		r.Effort = effortOf(q.Reasoning.Effort)
		r.Thinking = true
		r.ThinkOff = strings.EqualFold(strings.TrimSpace(q.Reasoning.Effort), "none")
	}
	var found []rTool
	var s string
	if decodeJSON(q.Input, &s) == nil {
		r.Messages = append(r.Messages, Message{Role: "user", Parts: []Part{{Kind: Text, Text: s}}})
	} else {
		var items []rItem
		if err := decode(q.Input, &items); err != nil {
			return nil, fmt.Errorf("invalid input: %v", err)
		}

		replied := false

		var mode string
		var sysModes []string
		var rawItems []json.RawMessage
		for i, it := range items {
			if it.Role == "assistant" || strings.HasPrefix(it.Type, "function_call") || strings.HasPrefix(it.Type, "custom_tool_call") || strings.HasPrefix(it.Type, "tool_search") || it.Type == "reasoning" {
				replied = true
			}
			switch {
			case it.Type == "input_file":

				if mt := videoFileType(it.FileData, it.Filename); mt != "" {
					if v, ok := videoPart(it.FileData, mt, it.Filename); ok {
						r.Messages = append(r.Messages, Message{Role: "user", Parts: []Part{v}})
					}
				} else if p, ok := chatFile(it.FileData, it.FileID, it.Filename); ok {
					r.Messages = append(r.Messages, Message{Role: "user", Parts: []Part{p}})
				}
			case it.Type == "message" || (it.Type == "" && it.Role != ""):
				role := "user"
				if it.Role == "assistant" {
					role = "assistant"
				}
				var parts []Part
				if !facts || role != "assistant" {
					parts = responsesParts(it.Content)
				}
				if it.Role == "system" || it.Role == "developer" {
					for _, p := range parts {
						if p.Kind == Text && p.Text != "" {
							r.systemParts = append(r.systemParts, p.Text)
						}
						if isCollaborationMode(p) {
							mode = p.Text
							if !replied && !keepInstructions {
								sysModes = append(sysModes, p.Text)
							}
						}
					}
				}
				if keepInstructions && (it.Role == "system" || it.Role == "developer") {
					r.Messages = append(r.Messages, Message{Role: it.Role, Parts: parts})
					continue
				}
				if (it.Role == "system" || it.Role == "developer") && replied {

					if t := text(parts); t != "" {
						r.Messages = append(r.Messages, Message{Role: "user", Parts: []Part{{Kind: Text, Text: "<system-reminder>\n" + t + "\n</system-reminder>"}}})
					}
					continue
				}
				if it.Role == "system" || it.Role == "developer" {
					if t := text(parts); t != "" {
						if r.System != "" {
							r.System += "\n\n"
						}
						r.System += t
					}
					continue
				}
				r.Messages = append(r.Messages, Message{Role: role, Parts: parts})
			case it.Type == "configuration_update":

				if it.Reasoning != nil && it.Reasoning.Effort != "" {
					r.Effort = effortOf(it.Reasoning.Effort)
					r.Thinking = true
					r.ThinkOff = strings.EqualFold(strings.TrimSpace(it.Reasoning.Effort), "none")
				}
			case it.Type == "agent_message":

				if parts := responsesParts(it.Content); len(parts) > 0 {
					r.Messages = append(r.Messages, Message{Role: "user", Parts: parts})
				}
			case it.Type == "function_call":
				name := it.Name
				if it.Namespace != "" {
					name = flatName(it.Namespace, it.Name)
				}
				r.Messages = append(r.Messages, Message{Role: "assistant", Parts: []Part{{Kind: ToolCall, ID: it.CallID, Name: name, Args: parseArgs(string(it.Arguments))}}})
			case it.Type == "custom_tool_call":
				name := it.Name
				if it.Namespace != "" {
					name = flatName(it.Namespace, it.Name)
				}
				args, _ := json.Marshal(map[string]string{"input": it.Input})
				r.Messages = append(r.Messages, Message{Role: "assistant", Parts: []Part{{Kind: ToolCall, ID: it.CallID, Name: name, Args: args}}})
			case it.Type == "tool_search_call":
				r.Messages = append(r.Messages, Message{Role: "assistant", Parts: []Part{{Kind: ToolCall, ID: it.CallID, Name: toolSearch, Args: parseArgs(string(it.Arguments))}}})
			case it.Type == "tool_search_output":
				found = append(found, it.Tools...)
				r.Messages = append(r.Messages, Message{Role: "user", Parts: []Part{{Kind: ToolResult, CallID: it.CallID, Text: searchFound(it.Tools)}}})
			case (it.Type == "function_call_output" || it.Type == "custom_tool_call_output") && facts:
				r.Messages = append(r.Messages, Message{Role: "user", Parts: []Part{{Kind: ToolResult, CallID: it.CallID}}})
			case it.Type == "function_call_output" || it.Type == "custom_tool_call_output":
				out, images, audio := toolOutput(it.Output)
				part := Part{Kind: ToolResult, CallID: it.CallID, Text: out, Images: images, Audio: audio}
				if it.CallID == "" {

					if rawItems == nil {
						_ = decodeJSON(q.Input, &rawItems)
					}
					_ = decodeJSON(rawItems[i], &part.Standalone)
				}
				r.Messages = append(r.Messages, Message{Role: "user", Parts: []Part{part}})
			case it.Type == "reasoning":

				var b strings.Builder
				var content []rText
				_ = decodeJSON(it.Content, &content)
				for _, c := range content {
					if c.Type == "reasoning_text" {
						b.WriteString(c.Text)
					}
				}
				if b.Len() == 0 {
					for _, s := range it.Summary {
						b.WriteString(s.Text)
					}
				}
				part := Part{Kind: Thinking, Text: b.String()}
				if block, ours := claudeseal.Open(it.EncryptedContent); ours {

					part = claudePart(block, part)
				} else if it.EncryptedContent != "" {

					if rawItems == nil {
						_ = decodeJSON(q.Input, &rawItems)
					}
					if i < len(rawItems) {
						part.Sealed, part.SealedBy = rawItems[i], sealResponses
					}
				}
				if part.Text != "" || part.Sealed != nil || part.Signature != "" {
					r.Messages = append(r.Messages, Message{Role: "assistant", Parts: []Part{part}})
				}
			case it.Type == "web_search_call" && it.Action != nil && strings.TrimSpace(it.Action.Query) != "":

				var hits []Hit
				for _, s := range it.Action.Sources {
					if s.URL != "" {
						hits = append(hits, Hit{URL: s.URL})
					}
				}
				r.Messages = append(r.Messages, Message{Role: "assistant", Parts: []Part{{Kind: Search, ID: it.ID, Text: it.Action.Query, Hits: hits}}})
			}
		}
		r.System = latestModeInSystem(r.System, sysModes, mode)
	}
	r.Messages = mergeTurns(r.Messages)
	sent := len(q.Tools)
	offer := func(i int, t Tool, ns nsTool) {

		if i >= sent && slices.ContainsFunc(r.Tools, func(o Tool) bool { return o.Name == t.Name }) {
			return
		}
		if ns != (nsTool{}) {
			if r.Namespaced == nil {
				r.Namespaced = map[string]nsTool{}
			}
			r.Namespaced[t.Name] = ns
		}
		r.Tools = append(r.Tools, t)
	}

	for i, t := range append(q.Tools, found...) {
		if strings.HasPrefix(t.Type, "web_search") {
			r.WebSearch = true
			if len(t.ExternalWebAccess) > 0 {
				r.WebAccess = t.ExternalWebAccess
			}
		}
		switch t.Type {
		case "function":
			offer(i, Tool{Name: t.Name, Description: t.Description, Schema: unsealed(t.Parameters), Strict: t.Strict != nil && *t.Strict, StrictSpecified: t.Strict != nil}, nsTool{})
		case "custom":
			offer(i, Tool{Name: t.Name, Description: customDescription(t), Schema: customSchema}, nsTool{Name: t.Name, Custom: true})
		case "namespace":

			for _, nt := range t.Tools {
				flat := flatName(t.Name, nt.Name)
				switch nt.Type {
				case "function":
					offer(i, Tool{Name: flat, Description: nt.Description, Schema: unsealed(nt.Parameters), Strict: nt.Strict != nil && *nt.Strict, StrictSpecified: nt.Strict != nil}, nsTool{Namespace: t.Name, Name: nt.Name})
				case "custom":
					offer(i, Tool{Name: flat, Description: customDescription(nt), Schema: customSchema}, nsTool{Namespace: t.Name, Name: nt.Name, Custom: true})
				}
			}
		case toolSearch:
			if t.Execution == "client" {
				offer(i, Tool{Name: toolSearch, Description: t.Description, Schema: t.Parameters}, nsTool{Search: true})
			}
		}
	}
	var tc string
	if decodeJSON(q.ToolChoice, &tc) == nil {
		r.ToolChoice = tc
	} else {
		var o struct {
			Type  string `json:"type"`
			Name  string `json:"name"`
			Mode  string `json:"mode"`
			Tools []struct {
				Type      string `json:"type"`
				Name      string `json:"name"`
				Namespace string `json:"namespace"`
			} `json:"tools"`
		}
		if decodeJSON(q.ToolChoice, &o) == nil {
			switch o.Type {
			case "allowed_tools":
				if o.Mode != "auto" && o.Mode != "required" {
					return nil, fmt.Errorf("invalid allowed_tools mode %q", o.Mode)
				}
				r.ToolChoice = o.Mode
				allowed := make(map[string]bool, len(o.Tools))
				webSearch := false
				for _, tool := range o.Tools {
					switch {
					case (tool.Type == "function" || tool.Type == "custom") && tool.Name != "":
						if tool.Namespace != "" {
							allowed[flatName(tool.Namespace, tool.Name)] = true
						} else {
							allowed[tool.Name] = true
						}
					case strings.HasPrefix(tool.Type, "web_search"):
						webSearch = true
					}
				}
				r.WebSearch = r.WebSearch && webSearch
				var tools []Tool
				for _, tool := range r.Tools {
					if allowed[tool.Name] {
						tools = append(tools, tool)
					}
				}
				r.Tools = tools
				for name := range r.Namespaced {
					if !allowed[name] {
						delete(r.Namespaced, name)
					}
				}
			case "function":
				if o.Name != "" {
					r.ToolChoice = "name:" + o.Name
				}
			}
		}
	}
	r.Messages = searchRoundsBack(r.Messages, searchTool(r.Tools).Name)
	return r, nil
}

func searchRoundsBack(msgs []Message, name string) []Message {
	if !slices.ContainsFunc(msgs, func(m Message) bool { return slices.ContainsFunc(m.Parts, isSearch) }) {
		return msgs
	}
	out := make([]Message, 0, len(msgs))
	n := 0
	for _, m := range msgs {
		if !slices.ContainsFunc(m.Parts, isSearch) {
			out = append(out, m)
			continue
		}
		if m.Role != "assistant" || !slices.ContainsFunc(m.Parts, claudeSigned) {
			m.Parts = slices.DeleteFunc(slices.Clone(m.Parts), isSearch)
			if len(m.Parts) > 0 {
				out = append(out, m)
			}
			continue
		}
		var cur []Part
		for _, p := range m.Parts {
			if !isSearch(p) {
				cur = append(cur, p)
				continue
			}
			n++
			id := p.ID
			if id == "" {
				id = fmt.Sprintf("call_search_back_%d", n)
			}
			args, _ := json.Marshal(map[string]string{"query": p.Text})
			result := "Searched the web for: " + p.Text
			if len(p.Hits) > 0 {
				result += "\nPages found:"
				for _, h := range p.Hits {
					result += "\n- " + h.URL
				}
			}
			cur = append(cur, Part{Kind: ToolCall, ID: id, Name: name, Args: args})
			out = append(out, Message{Role: "assistant", Parts: cur},
				Message{Role: "user", Parts: []Part{{Kind: ToolResult, CallID: id, Text: result}}})
			cur = nil
		}
		if len(cur) > 0 {
			out = append(out, Message{Role: "assistant", Parts: cur})
		}
	}
	return mergeTurns(out)
}

func isSearch(p Part) bool { return p.Kind == Search }

func claudeSigned(p Part) bool {
	return p.Kind == Thinking && (p.SignedBy == sealAnthropic && p.Signature != "" || p.sealedBy(sealAnthropic))
}

func toolCallItem(t string) bool {
	switch t {
	case "function_call", "custom_tool_call", "tool_search_call":
		return true
	}
	return false
}

func toolResultItem(t string) bool {
	switch t {
	case "function_call_output", "custom_tool_call_output", "tool_search_output":
		return true
	}
	return false
}

func pairToolItems(body []byte) []byte {
	if !bodyHas(body, `_call"`) {
		return body
	}
	var q map[string]json.RawMessage
	if decodeJSONView(body, &q) != nil {
		return body
	}
	input, isList := inputList(q["input"])
	if !isList {
		return body
	}
	type item struct {
		Type   string `json:"type"`
		CallID string `json:"call_id"`
	}
	items := make([]item, len(input))
	answered := map[string]bool{}
	for i, raw := range input {
		if decodeJSONView(raw, &items[i]) != nil {
			items[i] = item{}
		}
		if t := items[i].Type; (t == "function_call_output" || t == "custom_tool_call_output") && items[i].CallID != "" {
			answered[items[i].CallID] = true
		}
	}
	exchange := func(t string) bool {
		return toolCallItem(t) || toolResultItem(t)
	}
	out := make([]json.RawMessage, 0, len(input)+1)
	var synthetic []json.RawMessage
	for i, raw := range input {
		out = append(out, raw)
		it := items[i]
		if (it.Type == "function_call" || it.Type == "custom_tool_call") && it.CallID != "" && !answered[it.CallID] {
			kind := "function_call_output"
			if it.Type == "custom_tool_call" {
				kind = "custom_tool_call_output"
			}
			result, _ := marshalPlain(map[string]any{"type": kind, "call_id": it.CallID,
				"output": "[The result of this tool call is unavailable: the turn was interrupted.]"})
			synthetic = append(synthetic, result)
			answered[it.CallID] = true
		}
		if len(synthetic) > 0 && exchange(it.Type) && (i+1 == len(input) || !exchange(items[i+1].Type)) {
			out = append(out, synthetic...)
			synthetic = nil
		}
	}
	if len(out) == len(input) {
		return body
	}
	q["input"], _ = marshalPlain(out)
	encoded, err := marshalPlain(q)
	if err != nil {
		return body
	}
	return encoded
}

func mergeTurns(msgs []Message) []Message {
	var out []Message
	for _, m := range msgs {
		if n := len(out); n > 0 && out[n-1].Role == m.Role && (m.Role == "user" || m.Role == "assistant") {
			out[n-1].Parts = append(out[n-1].Parts, m.Parts...)
			continue
		}
		out = append(out, m)
	}
	return out
}

func responseInstructions(r *Request) *Request {
	if !slices.ContainsFunc(r.Messages, func(m Message) bool { return m.Role == "system" || m.Role == "developer" }) {
		return r
	}
	out := *r
	out.Messages = nil
	replied := false
	for _, m := range r.Messages {
		if m.Role == "assistant" || slices.ContainsFunc(m.Parts, func(p Part) bool {
			return p.Kind == ToolCall || p.Kind == ToolResult || p.Kind == Thinking
		}) {
			replied = true
		}
		if m.Role == "system" || m.Role == "developer" {
			if t := text(m.Parts); t != "" {
				if replied {
					out.Messages = append(out.Messages, Message{Role: "user", Parts: []Part{{Kind: Text, Text: "<system-reminder>\n" + t + "\n</system-reminder>"}}})
				} else {
					if out.System != "" {
						out.System += "\n\n"
					}
					out.System += t
				}
			}
			continue
		}
		out.Messages = append(out.Messages, m)
	}
	out.Messages = mergeTurns(out.Messages)
	return &out
}

func responsesParts(raw json.RawMessage) []Part {
	var s string
	if decodeJSON(raw, &s) == nil {
		if s == "" {
			return nil
		}
		return []Part{{Kind: Text, Text: s}}
	}
	var items []struct {
		Type     string `json:"type"`
		Text     string `json:"text"`
		ImageURL string `json:"image_url"`
		Detail   string `json:"detail"`
		FileData string `json:"file_data"`
		FileURL  string `json:"file_url"`
		FileID   string `json:"file_id"`
		Filename string `json:"filename"`
		File     struct {
			FileData string `json:"file_data"`
			FileID   string `json:"file_id"`
			Filename string `json:"filename"`
		} `json:"file"`
	}
	decodeJSON(raw, &items)
	var out []Part
	for _, it := range items {
		switch it.Type {
		case "input_text", "output_text", "text":
			out = append(out, Part{Kind: Text, Text: it.Text})
		case "input_image":
			if it.ImageURL != "" {
				im := imagePart(it.ImageURL)
				im.Detail = it.Detail
				out = append(out, im)
			}
		case "input_file":

			src := cmp.Or(it.FileData, it.FileURL, it.File.FileData)
			if mt := videoFileType(src, it.Filename); mt != "" {
				if v, ok := videoPart(src, mt, it.Filename); ok {
					out = append(out, v)
				}
			} else if p, ok := chatFile(src, cmp.Or(it.FileID, it.File.FileID), cmp.Or(it.Filename, it.File.Filename)); ok {
				out = append(out, p)
			}
		}
	}
	return out
}

func replaysReasoning(model, host string) bool {
	return strings.Contains(strings.ToLower(model), "deepseek") &&
		!slices.Contains([]string{"chatgpt.com", "api.openai.com", "api.x.ai", "api.githubcopilot.com"}, host) &&
		!strings.HasSuffix(host, ".openai.azure.com")
}

type stepKind int

const (
	stepOther stepKind = iota
	stepReasoning
	stepSaid
	stepCall
	stepOutput
	stepTurn
)

func stepKindOf(typ, role string) stepKind {
	switch {
	case typ == "reasoning":
		return stepReasoning
	case strings.HasSuffix(typ, "_output"):
		return stepOutput
	case strings.HasSuffix(typ, "_call"):
		return stepCall
	case (typ == "message" || typ == "") && role == "assistant":
		return stepSaid
	case typ == "message" || typ == "" && role != "":
		return stepTurn
	}
	return stepOther
}

func noReasoningItem() map[string]any {
	return map[string]any{"type": "reasoning", "summary": []any{},
		"content": []map[string]any{{"type": "reasoning_text", "text": noReasoning}}}
}

func reasonFirst[T any](items []T, kinds []stepKind, none T) (led []T, ok bool) {
	step := func(k stepKind) bool { return k == stepReasoning || k == stepSaid || k == stepCall }
	afterOutput := false
	for i := 0; i < len(items); {
		if !step(kinds[i]) {
			switch kinds[i] {
			case stepOutput:
				afterOutput = true
			case stepTurn:
				afterOutput = false
			}
			if ok {
				led = append(led, items[i])
			}
			i++
			continue
		}
		j, calls, first := i, false, -1
		for ; j < len(items) && step(kinds[j]); j++ {
			calls = calls || kinds[j] == stepCall
			if kinds[j] == stepReasoning && first < 0 {
				first = j
			}
		}
		if (calls || afterOutput) && first != i {
			if !ok {
				led, ok = append(make([]T, 0, len(items)+1), items[:i]...), true
			}
			if first < 0 {
				led = append(led, none)
			} else {
				led = append(led, items[first])
			}
			for x := i; x < j; x++ {
				if x != first {
					led = append(led, items[x])
				}
			}
		} else if ok {
			led = append(led, items[i:j]...)
		}
		i = j
	}
	if !ok {
		return items, false
	}
	return led, true
}

func sealedReasoning(p Part) bool {
	if !p.sealedBy(sealResponses) {
		return false
	}
	var it struct {
		Enc     string            `json:"encrypted_content"`
		Content []json.RawMessage `json:"content"`
	}
	return decodeJSON(p.Sealed, &it) == nil && it.Enc != "" && len(it.Content) == 0
}

func buildResponses(r *Request, model, host string, rejectTemp bool) []byte {

	if !r.instructionsKept {
		r = responseInstructions(r)
	}

	replay := replaysReasoning(model, host)
	var input []any

	deferred := map[string]Tool{}
	placed := map[string]bool{}
	if r.LoadedInPlace {
		for _, t := range r.Tools {
			if t.Deferred {
				deferred[t.Name] = t
			}
		}
	}
	var loaded []any
	flushLoaded := func() {
		if len(loaded) > 0 {
			input = append(input, map[string]any{"type": "additional_tools", "role": "developer", "tools": loaded})
			loaded = nil
		}
	}

	for _, m := range dropSecondAnswers(r.Messages) {
		var content []map[string]any
		flushMsg := func() {
			if len(content) == 0 {
				return
			}
			flushLoaded()
			input = append(input, map[string]any{"type": "message", "role": m.Role, "content": content})
			content = nil
		}
		for _, p := range m.Parts {
			switch p.Kind {
			case Text:
				if p.Text == "" && p.Signature != "" {
					continue
				}
				t := "input_text"
				if m.Role == "assistant" {
					t = "output_text"
				}
				content = append(content, map[string]any{"type": t, "text": p.Text})
			case File:
				if m.Role != "assistant" && p.MediaType == "application/pdf" && p.Data != "" {

					content = append(content, map[string]any{"type": "input_file", "filename": "document.pdf", "file_data": "data:" + p.MediaType + ";base64," + p.Data})
				} else {

					t := "input_text"
					if m.Role == "assistant" {
						t = "output_text"
					}
					content = append(content, map[string]any{"type": t, "text": attachmentText(p)})
				}
			case Image:
				if m.Role != "assistant" {
					content = append(content, map[string]any{"type": "input_image", "detail": responsesDetail(p.Detail), "image_url": dataURL(p)})
				}
			case Thinking:
				if !replay && sealedReasoning(p) {

					flushMsg()
					flushLoaded()
					input = append(input, p.Sealed)
				} else if replay && p.Text != "" {
					flushMsg()
					flushLoaded()
					input = append(input, map[string]any{"type": "reasoning", "summary": []any{},
						"content": []map[string]any{{"type": "reasoning_text", "text": p.Text}}})
				}
			case ToolCall:
				flushMsg()
				flushLoaded()
				id := p.ID
				if id == "" {
					id = "call_" + newID()
				}
				input = append(input, map[string]any{"type": "function_call", "call_id": id, "name": p.Name, "arguments": argsString(p)})
			case ToolResult:
				flushMsg()
				if p.Standalone != nil {
					input = append(input, p.Standalone)
					continue
				}
				var output any = p.Text
				if len(p.Images) > 0 {

					var items []map[string]any
					if strings.TrimSpace(p.Text) != "" {
						items = append(items, map[string]any{"type": "input_text", "text": p.Text})
					}
					for _, im := range p.Images {
						items = append(items, map[string]any{"type": "input_image", "detail": responsesDetail(im.Detail), "image_url": dataURL(im)})
					}
					output = items
				}
				input = append(input, map[string]any{"type": "function_call_output", "call_id": p.CallID, "output": output})
				for _, name := range p.Loads {
					if t, ok := deferred[name]; ok && !placed[name] {
						placed[name] = true
						loaded = append(loaded, responsesTool(t))
					}
				}
			}
		}
		flushMsg()
	}
	flushLoaded()
	if replay {

		kinds := make([]stepKind, len(input))
		for i, it := range input {
			var k struct {
				Type string `json:"type"`
				Role string `json:"role"`
			}
			switch v := it.(type) {
			case map[string]any:
				k.Type, _ = v["type"].(string)
				k.Role, _ = v["role"].(string)
			case json.RawMessage:
				decodeJSON(v, &k)
			}
			kinds[i] = stepKindOf(k.Type, k.Role)
		}
		input, _ = reasonFirst(input, kinds, any(noReasoningItem()))
	}
	if input == nil {
		input = []any{}
	}
	out := map[string]any{"model": model, "input": input, "stream": r.Stream, "store": false}
	if len(r.ClientMetadata) > 0 {
		out["client_metadata"] = r.ClientMetadata
	}
	if len(r.AccessPrograms) > 0 {
		out["access_programs"] = r.AccessPrograms
	}
	if len(r.Text) > 0 || r.Format != nil {
		text := map[string]any{}
		decodeJSON(r.Text, &text)
		if r.Format != nil {
			text["format"] = r.Format.responses()
		}
		out["text"] = text
	}
	if r.CacheKey != "" {
		out["prompt_cache_key"] = r.CacheKey
	}
	if r.System != "" {
		out["instructions"] = r.System
	}
	if r.MaxTokens > 0 {
		out["max_output_tokens"] = r.MaxTokens
	}
	if !rejectTemp {
		if r.Temp != nil {
			out["temperature"] = *r.Temp
		}
		if r.TopP != nil {
			out["top_p"] = *r.TopP
		}
	}

	if r.Fast && (host == "chatgpt.com" || host == "api.openai.com") {
		out["service_tier"] = "priority"
	}

	if r.Ultrafast && host == "chatgpt.com" {
		out["service_tier"] = "ultrafast"
	}
	if r.OwnTier && r.Tier != "" {
		out["service_tier"] = r.Tier
	}
	if r.Effort != "" {
		out["reasoning"] = map[string]any{"effort": r.Effort, "summary": "auto"}
	} else if r.Thinking {
		out["reasoning"] = map[string]any{"summary": "auto"}
	}

	var include []string
	for _, v := range r.Include {
		if v == "" || slices.Contains(include, v) || (v == "reasoning.encrypted_content" && out["reasoning"] == nil) ||
			v == outputReplay && host != "chatgpt.com" && host != "api.openai.com" || !includeTaken(host, v) {
			continue
		}
		include = append(include, v)
	}
	if len(r.Tools) > 0 || r.WebSearch {
		var tools []map[string]any
		for _, t := range r.Tools {
			if placed[t.Name] {
				continue
			}
			tools = append(tools, responsesTool(t))
		}
		if r.WebSearch {
			tools = append(tools, map[string]any{"type": "web_search"})

			if host != "api.x.ai" && includeTaken(host, "web_search_call.action.sources") && !slices.Contains(include, "web_search_call.action.sources") {
				include = append(include, "web_search_call.action.sources")
			}
		}
		if len(tools) > 0 {
			out["tools"] = tools
		}
		switch {
		case r.ToolChoice == "auto" || r.ToolChoice == "none" || r.ToolChoice == "required":
			out["tool_choice"] = r.ToolChoice
		case strings.HasPrefix(r.ToolChoice, "name:"):
			out["tool_choice"] = map[string]any{"type": "function", "name": strings.TrimPrefix(r.ToolChoice, "name:")}
		}
		if r.Parallel != nil {
			out["parallel_tool_calls"] = *r.Parallel
		}
	} else if r.ToolChoice == "none" {

		out["tool_choice"] = "none"
	}
	if len(include) > 0 {
		out["include"] = include
	}
	b, _ := marshalBody(out, "input")

	return pairToolItems(b)
}

func responsesTool(t Tool) map[string]any {
	tool := map[string]any{"type": "function", "name": t.Name, "description": t.Description, "strict": t.Strict}
	if len(t.Schema) > 0 {
		tool["parameters"] = t.Schema
	}
	return tool
}

type rUsage struct {
	InputTokens        int `json:"input_tokens"`
	OutputTokens       int `json:"output_tokens"`
	TotalTokens        int `json:"total_tokens"`
	InputTokensDetails struct {
		CachedTokens int `json:"cached_tokens"`

		CacheWriteTokens int `json:"cache_write_tokens"`
	} `json:"input_tokens_details"`
	OutputTokensDetails struct {
		ReasoningTokens int `json:"reasoning_tokens"`
	} `json:"output_tokens_details"`
}

func (u rUsage) usage() Usage {
	d := u.InputTokensDetails
	return Usage{Input: max(u.InputTokens-d.CachedTokens-d.CacheWriteTokens, 0), Output: u.OutputTokens,
		CacheRead: d.CachedTokens, CacheWrite: d.CacheWriteTokens, Reasoning: u.OutputTokensDetails.ReasoningTokens}
}

func (u Usage) responses() map[string]any {
	in := u.prompt()
	return map[string]any{"input_tokens": in, "output_tokens": u.Output, "total_tokens": in + u.Output,
		"input_tokens_details":  map[string]any{"cached_tokens": u.CacheRead, "cache_write_tokens": u.CacheWrite},
		"output_tokens_details": map[string]any{"reasoning_tokens": u.Reasoning}}
}

type responsesDecoder struct {
	started bool
	called  bool
	calling bool
	sent    strings.Builder
	held    string
	whole   jsonWhole
	full    string

	waiting []*rCall
	giving  *rCall

	addedID map[int]string
}

type rCall struct {
	itemID string
	index  int
	lines  []string
	ended  bool
}

func (d *responsesDecoder) waitingCall(itemID string, index *int) *rCall {
	if itemID != "" {
		for _, c := range d.waiting {
			if c.itemID == itemID {
				return c
			}
		}
	}
	if index != nil {
		for _, c := range d.waiting {
			if c.index == *index {
				return c
			}
		}
	}
	if itemID == "" && index == nil && !d.calling && len(d.waiting) > 0 {
		return d.waiting[0]
	}
	return nil
}

func (d *responsesDecoder) give(c *rCall, emit func(Event)) error {
	d.waiting = slices.DeleteFunc(d.waiting, func(w *rCall) bool { return w == c })
	d.giving = c
	defer func() { d.giving = nil }()
	for _, line := range c.lines {
		if err := d.decode(line, emit); err != nil {
			return err
		}
	}
	return nil
}

func (d *responsesDecoder) giveWaiting(all bool, emit func(Event)) error {
	calls := slices.Clone(d.waiting)
	slices.SortStableFunc(calls, func(a, b *rCall) int { return cmp.Compare(a.index, b.index) })
	for _, c := range calls {
		if all || c.ended {
			if err := d.give(c, emit); err != nil {
				return err
			}
		}
	}
	if all {
		d.endCall(emit)
	}
	return nil
}

func (d *responsesDecoder) argsDelta(delta string, emit func(Event)) {
	if d.whole.feed(delta) {
		d.held += delta
		return
	}
	text := d.held + delta
	d.held = ""
	d.sent.WriteString(text)
	if text != "" {
		emit(Event{Kind: KToolArgs, Text: text})
	}
}

func (d *responsesDecoder) endCall(emit func(Event)) {
	if !d.calling {
		return
	}
	d.calling = false
	sent := d.sent.String()
	rest := d.held
	if args := pickArgs(sent+d.held, d.full); strings.HasPrefix(args, sent) {
		rest = args[len(sent):]
	}
	d.sent.Reset()
	d.held, d.full, d.whole = "", "", jsonWhole{}
	if rest != "" {
		emit(Event{Kind: KToolArgs, Text: rest})
	}
}

type jsonWhole struct {
	depth    int
	str, esc bool
	began    bool
}

func (j *jsonWhole) feed(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case j.esc:
			j.esc = false
		case j.str:
			if c == '\\' {
				j.esc = true
			} else if c == '"' {
				j.str = false
			}
		case c == '"':
			j.str = true
			if j.depth == 0 {
				j.began = false
			}
		case c == '{' || c == '[':
			j.depth++
			j.began = true
		case c == '}' || c == ']':
			j.depth--
		case c != ' ' && c != '\t' && c != '\n' && c != '\r' && j.depth == 0:
			j.began = false
		}
	}
	return j.began && j.depth == 0 && !j.str
}

func pickArgs(streamed, done string) string {
	s, f := strings.TrimSpace(streamed), strings.TrimSpace(done)
	switch sv, fv := json.Valid([]byte(s)), json.Valid([]byte(f)); {
	case fv && (!sv || len(f) > len(s)):
		return done
	case sv || f == "":
		return streamed
	default:
		return done
	}
}

func (d *responsesDecoder) decode(data string, emit func(Event)) error {
	var ev struct {
		Type  string `json:"type"`
		Delta string `json:"delta"`
		Item  rItem  `json:"item"`

		ItemID      string `json:"item_id"`
		OutputIndex *int   `json:"output_index"`

		Arguments string `json:"arguments"`
		Response  struct {
			ID                string `json:"id"`
			Model             string `json:"model"`
			Status            string `json:"status"`
			Usage             rUsage `json:"usage"`
			IncompleteDetails *struct {
				Reason string `json:"reason"`
			} `json:"incomplete_details"`
			Error *struct {
				Message string `json:"message"`
			} `json:"error"`
			Output []rItem `json:"output"`
		} `json:"response"`
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
		Message string `json:"message"`
	}
	if err := decodeJSON([]byte(data), &ev); err != nil {

		if e, ok := carriedError(data); ok {
			d.endCall(emit)
			emit(e)
		}
		return nil
	}
	switch ev.Type {
	case "response.created":
		if !d.started {
			d.started = true
			emit(Event{Kind: KStart, MsgID: ev.Response.ID, Model: ev.Response.Model})
		}
	case "response.output_item.added":
		d.endCall(emit)
		if ev.Item.Type == "function_call" {
			if d.giving == nil {

				c := &rCall{itemID: ev.Item.ID, lines: []string{data}}
				if ev.OutputIndex != nil {
					c.index = *ev.OutputIndex
				}
				d.waiting = append(d.waiting, c)
				return nil
			}
			d.called, d.calling = true, true
			emit(Event{Kind: KToolStart, ID: ev.Item.CallID, Name: ev.Item.Name})
		}
		if ev.Item.Type == "reasoning" {

			emit(Event{Kind: KThinkStart, ID: ev.Item.ID})
			if d.addedID == nil {
				d.addedID = map[int]string{}
			}
			if ev.OutputIndex != nil {
				d.addedID[*ev.OutputIndex] = ev.Item.ID
			}
		}
	case "response.output_text.delta":
		d.endCall(emit)
		emit(Event{Kind: KText, Text: ev.Delta})
	case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
		d.endCall(emit)
		emit(Event{Kind: KThink, Text: ev.Delta})
	case "response.function_call_arguments.delta":
		if d.giving == nil {
			if c := d.waitingCall(ev.ItemID, ev.OutputIndex); c != nil {
				c.lines = append(c.lines, data)
				if d.calling {
					return nil
				}
				return d.give(c, emit)
			}
		}
		if d.calling {
			d.argsDelta(ev.Delta, emit)
		} else {
			emit(Event{Kind: KToolArgs, Text: ev.Delta})
		}
	case "response.function_call_arguments.done":
		if d.giving == nil {
			if c := d.waitingCall(ev.ItemID, ev.OutputIndex); c != nil {
				c.lines = append(c.lines, data)
				return nil
			}
		}
		if d.calling && ev.Arguments != "" {
			d.full = ev.Arguments
		}
	case "response.output_item.done":
		if ev.Item.Type == "function_call" {
			if d.giving == nil {
				if c := d.waitingCall(ev.Item.ID, ev.OutputIndex); c != nil {
					c.lines = append(c.lines, data)
					c.ended = true
					if d.calling {
						return nil
					}
					return d.give(c, emit)
				}
			}
			if ev.Item.Arguments != "" {
				d.full = string(ev.Item.Arguments)
			}
			d.endCall(emit)

			if d.giving == nil {
				if err := d.giveWaiting(false, emit); err != nil {
					return err
				}
			}
			return nil
		}
		if ev.Item.Type == "reasoning" && ev.Item.EncryptedContent != "" {

			if ev.OutputIndex != nil {
				if a := d.addedID[*ev.OutputIndex]; a != "" {
					ev.Item.ID = a
				}
			}
			var whole struct {
				Item json.RawMessage `json:"item"`
			}
			if decodeJSON([]byte(data), &whole) == nil && len(whole.Item) > 0 {
				emit(Event{Kind: KSealed, Name: sealResponses, ID: ev.Item.ID, Text: string(whole.Item)})
			}
		}
		if a := ev.Item.Action; ev.Item.Type == "web_search_call" && a != nil && a.Query != "" {
			var hits []Hit
			for _, src := range a.Sources {
				if src.URL != "" {
					hits = append(hits, Hit{Title: src.URL, URL: src.URL})
				}
			}
			emit(Event{Kind: KSearch, Text: a.Query, Hits: hits})
		}
	case "response.completed", "response.incomplete", "response.failed":
		d.endCall(emit)
		if ev.Response.Error != nil || ev.Type == "response.failed" || ev.Response.Status == "failed" {

			msg := ""
			if ev.Response.Error != nil {
				msg = ev.Response.Error.Message
			}
			status, said := requestRefused(data)
			code, fs, fsaid := filterRefused(data)
			if status == 0 {
				status, said = fs, fsaid
			}
			emit(Event{Kind: KError, Text: cmp.Or(msg, streamErrorText(data)), Code: code, Status: status, Said: said})
			return nil
		}

		if err := d.giveWaiting(true, emit); err != nil {
			return err
		}
		stop := "stop"
		if ev.Response.Status == "incomplete" {
			stop = "length"
			if ev.Response.IncompleteDetails != nil && ev.Response.IncompleteDetails.Reason == "content_filter" {
				stop = "filter"
			}
		} else if d.called {

			stop = "tool"
		} else {
			for _, it := range ev.Response.Output {
				if it.Type == "function_call" {
					stop = "tool"
				}
			}
		}
		emit(Event{Kind: KStop, Stop: stop})
		emit(Event{Kind: KUsage, Usage: ev.Response.Usage.usage()})
	case "error":
		d.endCall(emit)
		msg := ev.Message
		if ev.Error != nil {
			msg = cmp.Or(ev.Error.Message, msg)
		}
		status, said := requestRefused(data)
		code, fs, fsaid := filterRefused(data)
		if status == 0 {
			status, said = fs, fsaid
		}
		emit(Event{Kind: KError, Text: cmp.Or(msg, streamErrorText(data)), Code: code, Status: status, Said: said})
	}
	return nil
}

func requestRefused(data string) (int, json.RawMessage) {
	for _, path := range []string{"error", "response.error"} {
		e := gjson.Get(data, path)
		if e.IsObject() && e.Get("type").String() == "invalid_request_error" {
			return http.StatusBadRequest, json.RawMessage(`{"error":` + e.Raw + `}`)
		}
	}
	return 0, nil
}

func saidError(failed map[string]any, said json.RawMessage) {
	e := gjson.GetBytes(said, "error")
	for _, k := range []string{"type", "code", "param"} {
		if v := e.Get(k); v.Type == gjson.String && v.String() != "" {
			failed[k] = v.String()
		}
	}
}

type responsesEncoder struct {
	w              *sseWriter
	model          string
	id             string
	created        int64
	seq            int
	started        bool
	usageAvailable bool
	item           int
	open           Kind
	itemID         string
	text           strings.Builder

	thinkNew bool
	thinkID  string
	thinkUp  string

	sig           strings.Builder
	bare          bool
	output        []any
	col           collector
	named         map[string]nsTool
	requestFields map[string]json.RawMessage

	call Part

	input customStream

	heldMsg map[string]any
	held    []heldEvent
}

type heldEvent struct {
	typ    string
	fields map[string]any
}

func callTo(item map[string]any, name string, named map[string]nsTool) map[string]any {
	if q := named[name]; q.Search {

		args, _ := item["arguments"].(string)
		delete(item, "name")
		item["type"], item["execution"], item["arguments"] = "tool_search_call", "client", parseArgs(args)
	} else if q.Custom {

		args, _ := item["arguments"].(string)
		delete(item, "arguments")
		item["type"], item["name"], item["input"] = "custom_tool_call", q.Name, ""
		if args != "" {
			item["input"] = customInput(args)
		}
		if q.Namespace != "" {
			item["namespace"] = q.Namespace
		}
	} else if q, ok := named[name]; ok {
		item["name"], item["namespace"] = q.Name, q.Namespace

		item["encrypted_function_args"] = []any{}
	} else {
		item["name"] = name
	}
	return item
}

func itemPrefix(item map[string]any) string {
	if t, _ := item["type"].(string); openaiItemPrefix[t] != "" {
		return openaiItemPrefix[t]
	}
	return "fc_"
}

func (e *responsesEncoder) send(typ string, fields map[string]any) {
	if e.heldMsg != nil {
		e.held = append(e.held, heldEvent{typ, fields})
		if len(e.held) > heldMost {
			e.release("")
		}
		return
	}
	e.write(typ, fields)
}

func (e *responsesEncoder) write(typ string, fields map[string]any) {
	fields["type"] = typ
	fields["sequence_number"] = e.seq
	e.seq++
	e.w.event(typ, fields)
}

func (e *responsesEncoder) release(phase string) {
	if e.heldMsg == nil {
		return
	}
	if phase != "" {
		e.heldMsg["phase"] = phase
	}
	held := e.held
	e.heldMsg, e.held = nil, nil
	for _, h := range held {
		e.write(h.typ, h.fields)
	}
}

func (e *responsesEncoder) response(status string, extra map[string]any) map[string]any {

	output := e.output
	if output == nil {
		output = []any{}
	}
	out := map[string]any{"id": e.id, "object": "response", "created_at": e.created, "status": status,
		"model": e.model, "output": output, "parallel_tool_calls": true, "tool_choice": "auto", "tools": []any{}}
	for key, value := range e.requestFields {
		out[key] = value
	}
	for k, v := range extra {
		out[k] = v
	}
	return out
}

func (e *responsesEncoder) start(ev Event) {
	if e.started {
		return
	}
	e.started, e.item = true, -1
	e.id, e.created = ev.MsgID, time.Now().Unix()
	if e.id == "" {
		e.id = newID()
	}
	if !strings.HasPrefix(e.id, "resp_") {
		e.id = "resp_" + e.id
	}
	if ev.Model != "" {
		e.model = ev.Model
	}
	e.send("response.created", map[string]any{"response": e.response("in_progress", nil)})
	e.send("response.in_progress", map[string]any{"response": e.response("in_progress", nil)})
}

func (e *responsesEncoder) closeItem() {
	e.closeAs(nil)
}

func (e *responsesEncoder) closeAs(sealed json.RawMessage) {
	if e.open == "" {
		return
	}
	var item any
	switch e.open {
	case Text:
		t := e.text.String()
		e.send("response.output_text.done", map[string]any{"item_id": e.itemID, "output_index": e.item, "content_index": 0, "text": t, "logprobs": []any{}})
		part := map[string]any{"type": "output_text", "text": t, "annotations": []any{}, "logprobs": []any{}}
		e.send("response.content_part.done", map[string]any{"item_id": e.itemID, "output_index": e.item, "content_index": 0, "part": part})
		m := map[string]any{"id": e.itemID, "type": "message", "role": "assistant", "status": "completed", "content": []map[string]any{part}}

		e.release(phaseCommentary)
		item, e.heldMsg = m, m
	case Thinking:
		t := e.text.String()
		summary := []map[string]any{}
		if !e.bare {
			e.send("response.reasoning_summary_text.done", map[string]any{"item_id": e.itemID, "output_index": e.item, "summary_index": 0, "text": t})
			part := map[string]any{"type": "summary_text", "text": t}
			e.send("response.reasoning_summary_part.done", map[string]any{"item_id": e.itemID, "output_index": e.item, "summary_index": 0, "part": part})
			summary = append(summary, part)
		}
		m := map[string]any{"id": e.itemID, "type": "reasoning", "status": "completed", "summary": summary}
		if e.sig.Len() > 0 {

			m["encrypted_content"] = claudeThinking(t, e.sig.String())
		}
		item = m
		if sealed != nil {
			item = sealed
		}
	case ToolCall:
		args := strings.TrimSpace(e.text.String())
		if args == "" {
			args = "{}"
		}
		p := e.call
		item = callTo(map[string]any{"id": e.itemID, "type": "function_call", "status": "completed", "call_id": p.ID, "arguments": args}, p.Name, e.named)
		switch q := e.named[p.Name]; {
		case q.Custom:

			input, _ := item.(map[string]any)["input"].(string)
			e.send("response.custom_tool_call_input.done", map[string]any{"item_id": e.itemID, "output_index": e.item, "input": input})
		case !q.Search:
			e.send("response.function_call_arguments.done", callTo(map[string]any{"item_id": e.itemID, "output_index": e.item, "call_id": p.ID, "arguments": args}, p.Name, e.named))
		}
	}
	e.send("response.output_item.done", map[string]any{"output_index": e.item, "item": item})
	e.output = append(e.output, item)

	e.open, e.text, e.thinkUp = "", strings.Builder{}, ""
	e.sig, e.bare = strings.Builder{}, false
}

func (e *responsesEncoder) openItem(k Kind, prefix string, item map[string]any) {
	e.closeItem()
	if k != Thinking {
		e.release(phaseCommentary)
	}
	e.item++
	e.open, e.itemID = k, prefix+newID()
	if k == Thinking && e.thinkID != "" {
		e.itemID = e.thinkID
	}
	e.thinkNew, e.thinkID = false, ""
	item["id"] = e.itemID
	item["status"] = "in_progress"
	e.send("response.output_item.added", map[string]any{"output_index": e.item, "item": item})
}

func (e *responsesEncoder) event(ev Event) {
	if ev.Kind != KStart && !e.started {
		e.start(Event{})
	}
	switch ev.Kind {
	case KStart:
		e.start(ev)
	case KText:
		if ev.Text == "" {
			return
		}
		if e.open != Text {
			e.openItem(Text, "msg_", map[string]any{"type": "message", "role": "assistant", "content": []any{}})
			e.send("response.content_part.added", map[string]any{"item_id": e.itemID, "output_index": e.item, "content_index": 0,
				"part": map[string]any{"type": "output_text", "text": "", "annotations": []any{}, "logprobs": []any{}}})
		}
		e.text.WriteString(ev.Text)
		e.send("response.output_text.delta", map[string]any{"item_id": e.itemID, "output_index": e.item, "content_index": 0, "delta": ev.Text, "logprobs": []any{}})
	case KThink:
		if ev.Text == "" {
			return
		}
		if e.open != Thinking || e.thinkNew || e.bare {
			if e.open != Thinking || e.thinkNew {
				e.openItem(Thinking, "rs_", map[string]any{"type": "reasoning", "summary": []any{}})
			}
			e.bare = false
			e.send("response.reasoning_summary_part.added", map[string]any{"item_id": e.itemID, "output_index": e.item, "summary_index": 0,
				"part": map[string]any{"type": "summary_text", "text": ""}})
		}
		e.text.WriteString(ev.Text)
		e.send("response.reasoning_summary_text.delta", map[string]any{"item_id": e.itemID, "output_index": e.item, "summary_index": 0, "delta": ev.Text})
	case KThinkStart:
		e.thinkNew, e.thinkID, e.thinkUp = true, "", ev.ID
		if strings.HasPrefix(ev.ID, "rs_") {
			e.thinkID = ev.ID
		}
	case KSig:
		if ev.Name != sealAnthropic || ev.Text == "" {
			break
		}
		if e.open != Thinking || e.thinkNew {

			e.openItem(Thinking, "rs_", map[string]any{"type": "reasoning", "summary": []any{}})
			e.bare = true
		}
		e.sig.WriteString(ev.Text)
	case KSealed:
		if ev.Name == sealAnthropic {

			e.closeItem()
			e.item++
			e.thinkNew, e.thinkID = false, ""
			id := "rs_" + newID()
			e.send("response.output_item.added", map[string]any{"output_index": e.item,
				"item": map[string]any{"id": id, "type": "reasoning", "status": "in_progress", "summary": []any{}}})
			item := map[string]any{"id": id, "type": "reasoning", "status": "completed", "summary": []any{}, "encrypted_content": claudeseal.Seal([]byte(ev.Text))}
			e.send("response.output_item.done", map[string]any{"output_index": e.item, "item": item})
			e.output = append(e.output, item)
			break
		}
		if ev.Name != sealResponses {
			break
		}
		raw := json.RawMessage(ev.Text)
		if e.open == Thinking && !e.thinkNew && (ev.ID == "" || ev.ID == e.itemID || ev.ID == e.thinkUp) {

			e.closeAs(magpieMadeReasoningRaw(raw, e.itemID))
			break
		}

		raw = magpieMadeReasoningRaw(raw, "")
		e.closeItem()
		e.item++
		e.thinkNew, e.thinkID = false, ""
		e.send("response.output_item.added", map[string]any{"output_index": e.item, "item": raw})
		e.send("response.output_item.done", map[string]any{"output_index": e.item, "item": raw})
		e.output = append(e.output, raw)
	case KSearch:

		e.closeItem()
		e.release(phaseCommentary)
		e.item++
		item := responsesSearchItem(ev.Text, ev.Hits)
		e.send("response.output_item.added", map[string]any{"output_index": e.item, "item": item})
		e.send("response.web_search_call.completed", map[string]any{"output_index": e.item, "item_id": item["id"]})
		e.send("response.output_item.done", map[string]any{"output_index": e.item, "item": item})
		e.output = append(e.output, item)
	case KToolStart:
		if ev.ID == "" {
			ev.ID = "call_" + newID()
		}

		item := callTo(map[string]any{"type": "function_call", "call_id": ev.ID, "arguments": ""}, ev.Name, e.named)
		e.openItem(ToolCall, itemPrefix(item), item)
		e.call = Part{Kind: ToolCall, ID: ev.ID, Name: ev.Name}
		e.input = customStream{}
		e.col.add(ev)
		return
	case KToolArgs:
		if e.open == ToolCall && ev.Text != "" {
			e.text.WriteString(ev.Text)
			switch q := e.named[e.call.Name]; {
			case q.Custom:

				if in := e.input.feed(ev.Text); in != "" {
					e.send("response.custom_tool_call_input.delta", map[string]any{"item_id": e.itemID, "output_index": e.item, "delta": in})
				}
			default:
				e.send("response.function_call_arguments.delta", map[string]any{"item_id": e.itemID, "output_index": e.item, "delta": ev.Text})
			}
		}
	case KError:
		e.closeItem()
		e.release("")
		code := "server_error"
		if ev.Code != "" {
			code = ev.Code
		}
		failed := map[string]any{"code": code, "message": ev.Text}
		saidError(failed, ev.Said)
		e.send("response.failed", map[string]any{"response": e.response("failed", map[string]any{"error": failed})})
	}
	e.col.add(ev)
}

func (e *responsesEncoder) finish() {
	if !e.started {
		e.start(Event{})
	}
	e.closeItem()
	res := e.col.finish()
	status, typ := "completed", "response.completed"
	var usage any
	if e.usageAvailable {
		usage = res.Usage.responses()
	}
	extra := map[string]any{"usage": usage, "incomplete_details": nil}
	if res.Stop == "length" || res.Stop == "filter" {
		status, typ = "incomplete", "response.incomplete"
		reason := "max_output_tokens"
		if res.Stop == "filter" {
			reason = "content_filter"
		}
		extra["incomplete_details"] = map[string]any{"reason": reason}
	}
	if status == "completed" {
		e.release(phaseFinal)
	}
	e.release("")
	e.send(typ, map[string]any{"response": e.response(status, extra)})
}

func responsesSearchItem(query string, hits []Hit) map[string]any {
	sources := make([]map[string]any, 0, len(hits))
	for _, h := range hits {
		if h.URL != "" {
			sources = append(sources, map[string]any{"type": "url", "url": h.URL})
		}
	}
	return map[string]any{
		"id": "ws_" + newID(), "type": "web_search_call", "status": "completed",
		"action": map[string]any{"type": "search", "query": query, "queries": []string{query}, "sources": sources},
	}
}

func renderResponses(res Result, model string, named map[string]nsTool) []byte {
	output := []any{}
	for _, p := range res.Parts {
		switch p.Kind {
		case Text:
			if p.Text == "" && p.Signature != "" {
				continue
			}
			output = append(output, map[string]any{"id": "msg_" + newID(), "type": "message", "role": "assistant", "status": "completed",
				"content": []map[string]any{{"type": "output_text", "text": p.Text, "annotations": []any{}}}})
		case Thinking:
			if p.sealedBy(sealResponses) {

				output = append(output, magpieMadeReasoningRaw(p.Sealed, ""))
				continue
			}
			if p.sealedBy(sealAnthropic) {

				output = append(output, map[string]any{"id": "rs_" + newID(), "type": "reasoning", "status": "completed",
					"summary": []any{}, "encrypted_content": claudeseal.Seal(p.Sealed)})
				continue
			}
			claude := p.SignedBy == sealAnthropic && p.Signature != ""
			if p.Text == "" && !claude {
				continue
			}
			summary := []map[string]any{}
			if p.Text != "" {
				summary = append(summary, map[string]any{"type": "summary_text", "text": p.Text})
			}
			item := map[string]any{"id": "rs_" + newID(), "type": "reasoning", "status": "completed", "summary": summary}
			if claude {
				item["encrypted_content"] = claudeThinking(p.Text, p.Signature)
			}
			output = append(output, item)
		case ToolCall:
			id := p.ID
			if id == "" {
				id = "call_" + newID()
			}
			item := callTo(map[string]any{"type": "function_call", "status": "completed",
				"call_id": id, "arguments": argsString(p)}, p.Name, named)
			item["id"] = itemPrefix(item) + newID()
			output = append(output, item)
		case Search:
			output = append(output, responsesSearchItem(p.Text, p.Hits))
		}
	}
	id := res.ID
	if id == "" {
		id = newID()
	}
	if !strings.HasPrefix(id, "resp_") {
		id = "resp_" + id
	}
	if res.Model != "" {
		model = res.Model
	}
	status := "completed"
	var incomplete any
	switch res.Stop {
	case "length":
		status, incomplete = "incomplete", map[string]any{"reason": "max_output_tokens"}
	case "filter":

		status, incomplete = "incomplete", map[string]any{"reason": "content_filter"}
	}
	phaseOutput(output, status == "completed")
	b, _ := json.Marshal(map[string]any{"id": id, "object": "response", "created_at": time.Now().Unix(), "status": status,
		"model": model, "output": output, "usage": res.Usage.responses(), "incomplete_details": incomplete,
		"parallel_tool_calls": true, "tool_choice": "auto", "tools": []any{}, "error": nil})
	return b
}

func isCollaborationMode(p Part) bool {
	return p.Kind == Text && strings.HasPrefix(strings.TrimSpace(p.Text), "<collaboration_mode>")
}

func latestModeInSystem(system string, sysModes []string, mode string) string {
	for _, m := range sysModes {
		if m != mode {
			system = strings.ReplaceAll(system, m, mode)
		}
	}
	return system
}

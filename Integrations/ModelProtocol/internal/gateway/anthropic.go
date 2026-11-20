package gateway

import (
	"cmp"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"codexbridge/modelprotocol/internal/lazyre"
	"codexbridge/modelprotocol/internal/provider"
	"github.com/tidwall/gjson"
)

type aBlock struct {
	Type string `json:"type"`

	Text string `json:"text,omitempty"`

	Source *struct {
		Type      string `json:"type"`
		MediaType string `json:"media_type,omitempty"`
		Data      string `json:"data,omitempty"`
		URL       string `json:"url,omitempty"`
	} `json:"source,omitempty"`

	ID    string          `json:"id,omitempty"`
	Name  string          `json:"name,omitempty"`
	Input json.RawMessage `json:"input,omitempty"`

	ToolUseID string          `json:"tool_use_id,omitempty"`
	Content   json.RawMessage `json:"content,omitempty"`
	IsError   bool            `json:"is_error,omitempty"`

	Thinking  string `json:"thinking,omitempty"`
	Signature string `json:"signature,omitempty"`

	CacheControl map[string]string `json:"cache_control,omitempty"`

	sealed json.RawMessage
}

func (b aBlock) MarshalJSON() ([]byte, error) {
	type plain aBlock
	if len(b.sealed) > 0 {
		return b.sealed, nil
	}
	if b.Type != "thinking" {
		return json.Marshal(plain(b))
	}

	return json.Marshal(struct {
		plain
		Thinking  string `json:"thinking"`
		Signature string `json:"signature"`
	}{plain(b), b.Thinking, b.Signature})
}

var ephemeral = map[string]string{"type": "ephemeral"}

func addedMark(r *Request, model string) map[string]string {
	if r.hourMarks && anthropicModel.MatchString(model) {
		return cacheMark1h()
	}
	return ephemeral
}

type aRequest struct {
	Model        string          `json:"model"`
	System       json.RawMessage `json:"system,omitempty"`
	CacheControl json.RawMessage `json:"cache_control,omitempty"`
	Messages     []struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	} `json:"messages"`
	Tools []struct {
		Type         string          `json:"type,omitempty"`
		Name         string          `json:"name"`
		Description  string          `json:"description,omitempty"`
		InputSchema  json.RawMessage `json:"input_schema,omitempty"`
		Strict       *bool           `json:"strict,omitempty"`
		CacheControl json.RawMessage `json:"cache_control,omitempty"`
		DeferLoading bool            `json:"defer_loading,omitempty"`

		Model string `json:"model,omitempty"`
	} `json:"tools,omitempty"`
	ToolChoice *struct {
		Type                   string `json:"type"`
		Name                   string `json:"name,omitempty"`
		DisableParallelToolUse bool   `json:"disable_parallel_tool_use,omitempty"`
	} `json:"tool_choice,omitempty"`
	MaxTokens     int      `json:"max_tokens"`
	Temperature   *float64 `json:"temperature,omitempty"`
	TopP          *float64 `json:"top_p,omitempty"`
	StopSequences []string `json:"stop_sequences,omitempty"`
	Stream        bool     `json:"stream,omitempty"`
	Thinking      *struct {
		Type         string `json:"type"`
		BudgetTokens int    `json:"budget_tokens,omitempty"`
	} `json:"thinking,omitempty"`
	OutputConfig *struct {
		Effort string `json:"effort,omitempty"`
		Format *struct {
			Type   string          `json:"type"`
			Schema json.RawMessage `json:"schema"`
		} `json:"format,omitempty"`
	} `json:"output_config,omitempty"`
	Metadata   json.RawMessage `json:"metadata,omitempty"`
	Speed      string          `json:"speed,omitempty"`
	Safeguards json.RawMessage `json:"safeguards,omitempty"`
}

func parseAnthropic(body []byte) (*Request, error) {
	return parseAnthropicRequest(body, false)
}

func parseAnthropicRequest(body []byte, clientMarks bool) (*Request, error) {
	return readAnthropic(body, clientMarks, false)
}

func readAnthropic(body []byte, clientMarks, facts bool) (*Request, error) {
	return readAdvised(body, clientMarks, facts, false)
}

func readAdvised(body []byte, clientMarks, facts, advised bool) (*Request, error) {
	decode := decodeJSON
	if facts {
		decode = decodeJSONView
	}
	var a aRequest
	if err := decode(body, &a); err != nil {
		return nil, fmt.Errorf("invalid request: %v", err)
	}
	r := &Request{Model: a.Model, System: stringOrText(a.System), MaxTokens: a.MaxTokens,
		Temp: a.Temperature, TopP: a.TopP, Stop: a.StopSequences, Stream: a.Stream, Fast: a.Speed == "fast"}
	if len(a.System) > 0 {
		r.systemRaw = []json.RawMessage{a.System}
	}
	if !facts {
		r.askedTTL = askedCacheTTL(&a)
	}
	if clientMarks {
		var err error
		r.clientCache, err = readClientCache(a)
		if err != nil {
			return nil, err
		}
	}
	r.Safeguards = a.Safeguards
	if string(r.Safeguards) == "null" {
		r.Safeguards = nil
	}
	if len(a.Metadata) > 0 && string(a.Metadata) != "null" {
		r.Metadata = a.Metadata
	}
	if oc := a.OutputConfig; oc != nil && oc.Format != nil && oc.Format.Type == "json_schema" && len(oc.Format.Schema) > 0 {
		strict := true
		r.Format = &Format{Type: "json_schema", Name: formatName, Schema: oc.Format.Schema, Strict: &strict}
	}
	for mi, m := range a.Messages {
		msg := Message{Role: m.Role}
		if facts && m.Role == "assistant" {
			r.Messages = append(r.Messages, msg)
			continue
		}
		var s string
		if decodeJSON(m.Content, &s) == nil {
			if s != "" {
				msg.Parts = append(msg.Parts, Part{Kind: Text, Text: s})
			}
		} else {
			var blocks []aBlock
			if err := decode(m.Content, &blocks); err != nil {
				return nil, fmt.Errorf("invalid message content: %v", err)
			}
			var raws []json.RawMessage
			for i, b := range blocks {
				before := len(msg.Parts)
				switch b.Type {
				case "text":
					msg.Parts = append(msg.Parts, Part{Kind: Text, Text: b.Text, block: true})
				case "image":
					if b.Source != nil {
						msg.Parts = append(msg.Parts, Part{Kind: Image, MediaType: b.Source.MediaType, Data: b.Source.Data, URL: b.Source.URL, block: true})
					}
				case "video":

					if b.Source != nil {
						if v, ok := videoPart(cmp.Or(b.Source.Data, b.Source.URL), cmp.Or(b.Source.MediaType, "video/mp4"), ""); ok {
							v.block = true
							msg.Parts = append(msg.Parts, v)
						}
					}
				case "document":

					switch {
					case b.Source == nil:
					case b.Source.Type == "text":
						msg.Parts = append(msg.Parts, Part{Kind: Text, Text: b.Source.Data, block: true})
					case b.Source.Type == "base64" && b.Source.Data != "":
						msg.Parts = append(msg.Parts, Part{Kind: File, MediaType: b.Source.MediaType, Data: b.Source.Data, block: true})
					case b.Source.URL != "":
						msg.Parts = append(msg.Parts, Part{Kind: File, MediaType: b.Source.MediaType, URL: b.Source.URL, block: true})
					}
				case "tool_use":
					msg.Parts = append(msg.Parts, Part{Kind: ToolCall, ID: anthropicInID(b.ID), Name: b.Name, Args: b.Input, block: true})
				case "tool_result":
					if facts {
						msg.Parts = append(msg.Parts, Part{Kind: ToolResult, CallID: anthropicInID(b.ToolUseID)})
						break
					}
					out, images, audio := toolOutput(b.Content)
					msg.Parts = append(msg.Parts, Part{Kind: ToolResult, CallID: anthropicInID(b.ToolUseID), Text: out, Images: images, Audio: audio, IsError: b.IsError, Loads: toolRefs(b.Content), block: true})
				case "thinking":
					msg.Parts = append(msg.Parts, Part{Kind: Thinking, Text: b.Thinking, Signature: b.Signature, block: true})
				case "server_tool_use":

					if advised && b.Name == advisorTool {
						msg.Parts = append(msg.Parts, Part{Kind: ToolCall, ID: adviceInID(b.ID), Name: advisorTool, Args: json.RawMessage(`{}`), block: true})
					}
				case "advisor_tool_result", "advisor_tool_result_error":
					if advised {
						text, failed := adviceOf(b.Content)
						msg.Parts = append(msg.Parts, Part{Kind: ToolResult, CallID: adviceInID(b.ToolUseID), Text: text, IsError: failed, block: true})
					}
				case "redacted_thinking":

					if raws == nil {
						_ = decodeJSON(m.Content, &raws)
					}
					if i < len(raws) {
						msg.Parts = append(msg.Parts, Part{Kind: Thinking, Sealed: raws[i], SealedBy: sealAnthropic, block: true})
					}
				}
				if clientMarks && !(mi == len(a.Messages)-1 && i == len(blocks)-1) {
					if ttl := cacheTTL(b.CacheControl); ttl != "" {
						if len(msg.Parts) > before && renderedCacheBlock(b) {
							msg.Parts[len(msg.Parts)-1].cache = ttl
						} else {
							r.clientCache.droppedMessages++
						}
					}
				}
			}
		}
		if advised && msg.Role == "assistant" {
			r.Messages = append(r.Messages, adviceApart(msg)...)
			continue
		}
		r.Messages = append(r.Messages, msg)
	}
	for _, t := range a.Tools {
		if t.Type != "" && t.Type != "custom" && len(t.InputSchema) == 0 {

			if strings.HasPrefix(t.Type, "web_search") {
				r.WebSearch = true
			}
			if strings.HasPrefix(t.Type, "advisor_") {
				if advised {

					r.Advisor = cmp.Or(r.Advisor, t.Model)
					continue
				}

				for i := range r.Messages {
					for j, pt := range r.Messages[i].Parts {
						if pt.Kind == Text {
							r.Messages[i].Parts[j].Text, _ = advisorGoneIn(pt.Text)
						}
					}
				}
			}
			continue
		}
		if t.Name == "DeferredToolPlaceholder" {

			continue
		}
		r.Tools = append(r.Tools, Tool{Name: t.Name, Description: t.Description, Schema: t.InputSchema, Strict: t.Strict != nil && *t.Strict, StrictSpecified: t.Strict != nil, Deferred: t.DeferLoading})
	}
	if tc := a.ToolChoice; tc != nil {
		switch tc.Type {
		case "auto", "none":
			r.ToolChoice = tc.Type
		case "any":
			r.ToolChoice = "required"
		case "tool":
			r.ToolChoice = "name:" + tc.Name
		}
		if tc.DisableParallelToolUse {
			f := false
			r.Parallel = &f
		}
	}

	if th := a.Thinking; th != nil && (th.Type == "disabled" || th.Type == "between_tools") {
		r.ThinkOff = true
	} else if th != nil && (th.Type == "enabled" || th.Type == "adaptive") {
		r.Thinking = true
		r.Effort = effortOfBudget(th.BudgetTokens)
		if oc := a.OutputConfig; oc != nil && effortOf(oc.Effort) != "" {
			r.Effort = effortOf(oc.Effort)
		} else if e := turnEffort(body); e != "" {

			r.Effort = e
		}
	}
	if a.Thinking == nil && a.OutputConfig != nil && a.OutputConfig.Effort != "" {
		r.Effort = effortOf(a.OutputConfig.Effort)
		if r.Effort == "" {
			return nil, fmt.Errorf("unsupported output effort %q", a.OutputConfig.Effort)
		}
	}
	return r, nil
}

func turnEffort(body []byte) string {
	if !bodyHas(body, `"output_config"`) {
		return ""
	}
	last := ""
	for _, e := range gjson.GetBytes(body, "messages.#.output_config.effort").Array() {
		if v := effortOf(e.String()); v != "" {
			last = v
		}
	}
	return last
}

func anthropicReplaysThinking(host, model string) bool {
	if host == "api.anthropic.com" || anthropicModel.MatchString(model) {
		return false
	}
	return strings.Contains(host, "deepseek") || strings.Contains(strings.ToLower(model), "deepseek")
}

func withThinkingOnToolTurns(body []byte) []byte {
	if !bodyHas(body, `"tool_use"`) && !bodyHas(body, `"redacted_thinking"`) {
		return body
	}
	var q map[string]json.RawMessage
	var msgs []json.RawMessage
	if decodeJSON(body, &q) != nil || decodeJSON(q["messages"], &msgs) != nil {
		return body
	}
	space, _ := json.Marshal(aBlock{Type: "thinking", Thinking: noReasoning})
	changed := false

	afterTool := false
	for i, raw := range msgs {
		var m map[string]json.RawMessage
		var role string
		var blocks []json.RawMessage
		if decodeJSON(raw, &m) != nil || decodeJSON(m["role"], &role) != nil {
			afterTool = false
			continue
		}
		if role != "assistant" {
			afterTool = decodeJSON(m["content"], &blocks) == nil && len(blocks) > 0 &&
				!slices.ContainsFunc(blocks, func(b json.RawMessage) bool {
					var t struct {
						Type string `json:"type"`
					}
					return decodeJSON(b, &t) != nil || t.Type != "tool_result"
				})
			continue
		}
		after := afterTool
		afterTool = false
		if decodeJSON(m["content"], &blocks) != nil {
			continue
		}
		var out []json.RawMessage
		thought, called, edited := false, false, false
		for _, b := range blocks {
			var t struct {
				Type string `json:"type"`
			}
			decodeJSON(b, &t)
			switch t.Type {
			case "thinking":
				thought = true
			case "tool_use":
				called = true
			case "redacted_thinking":
				edited = true
				if thought {
					continue
				}
				b, thought = space, true
			}
			out = append(out, b)
		}
		if (called || after) && !thought {
			out = append([]json.RawMessage{space}, out...)
			edited = true
		}
		if !edited {
			continue
		}
		m["content"], _ = json.Marshal(out)
		if nb, err := json.Marshal(m); err == nil {
			msgs[i], changed = nb, true
		}
	}
	if !changed {
		return body
	}
	q["messages"], _ = json.Marshal(msgs)
	nb, err := marshalJSON(q)
	if err != nil {
		return body
	}
	return nb
}

var anthropicModel = lazyre.New(`(?i)(?:^|[/.:-])claude-`)

var claudeVersion = lazyre.New(`(?:^|[^a-z0-9])(?:claude-)?(?:opus|sonnet|haiku|fable|mythos)-(\d{1,2})(?:[-.](\d{1,2}))?(?:[^0-9]|$)|claude-(\d+)(?:[-.](\d))?-(?:opus|sonnet|haiku)`)

func adaptiveOnly(model string) bool {
	major, minor, ok := claudeVersionOf(model)
	return ok && (major > 4 || major == 4 && minor >= 6)
}

func noXhigh(model string) bool {
	major, minor, ok := claudeVersionOf(model)
	return ok && major == 4 && minor == 6
}

func claudeVersionOf(model string) (major, minor int, ok bool) {
	m := claudeVersion.FindStringSubmatch(strings.ToLower(model))
	if m == nil {
		return 0, 0, false
	}
	v := m[1:3]
	if m[3] != "" {
		v = m[3:5]
	}
	major, _ = strconv.Atoi(v[0])
	minor, _ = strconv.Atoi(v[1])
	return major, minor, true
}

var effortInOutputConfig = lazyre.New(`(?i)glm-5\.[23](?:$|[-.:/\[])|minimax-m3\.1-flash(?:$|[-.:/\[])|(?:^|[^a-z0-9])gpt-\d`)

const deepseekHost = provider.DeepSeekHost

func outputEffortAt(host, model string) bool {
	return host == deepseekHost || effortInOutputConfig.MatchString(model)
}

func imageBlock(p Part) aBlock {
	b := aBlock{Type: "image"}
	b.Source = &struct {
		Type      string `json:"type"`
		MediaType string `json:"media_type,omitempty"`
		Data      string `json:"data,omitempty"`
		URL       string `json:"url,omitempty"`
	}{}
	if p.URL != "" && p.Data == "" {
		b.Source.Type, b.Source.URL = "url", p.URL
	} else {
		b.Source.Type, b.Source.MediaType, b.Source.Data = "base64", p.MediaType, p.Data
	}
	return b
}

type aMessage struct {
	Role    string   `json:"role"`
	Content []aBlock `json:"content"`
}

const interruptedTool = "[The result of this tool call is unavailable: the turn was interrupted.]"

func buildAnthropic(r *Request, model string) []byte {
	return anthropicBody(r, model, "", false)
}

func anthropicBody(r *Request, model, host string, replay bool) []byte {
	r = responseInstructions(r)
	if r.Format != nil && r.Format.schema() == nil {

		r = r.inSystem()
	}
	var msgs []aMessage
	push := func(role string, blocks []aBlock) {
		if len(blocks) == 0 {
			return
		}
		if n := len(msgs); n > 0 && msgs[n-1].Role == role {
			msgs[n-1].Content = append(msgs[n-1].Content, blocks...)
			return
		}
		msgs = append(msgs, aMessage{Role: role, Content: blocks})
	}
	for _, m := range r.Messages {
		var results, rest []aBlock
		for _, p := range m.Parts {
			switch p.Kind {
			case Text:
				if strings.TrimSpace(p.Text) != "" {
					rest = append(rest, aBlock{Type: "text", Text: p.Text, CacheControl: partMark(p.cache)})
				}
			case File:
				if isVideo(p) && !r.videoOff {
					b := videoBlock(p)
					b.CacheControl = partMark(p.cache)
					rest = append(rest, b)
					break
				}
				if p.MediaType == "application/pdf" && p.Data != "" {

					rest = append(rest, aBlock{Type: "document", Source: &struct {
						Type      string `json:"type"`
						MediaType string `json:"media_type,omitempty"`
						Data      string `json:"data,omitempty"`
						URL       string `json:"url,omitempty"`
					}{Type: "base64", MediaType: p.MediaType, Data: p.Data}})
				} else {
					rest = append(rest, aBlock{Type: "text", Text: attachmentText(p)})
				}
			case Image:
				b := imageBlock(p)
				b.CacheControl = partMark(p.cache)
				rest = append(rest, b)
			case ToolCall:

				rest = append(rest, aBlock{Type: "tool_use", ID: anthropicOutID(p.ID), Name: p.Name, Input: argsOf(p), CacheControl: partMark(p.cache)})
			case ToolResult:
				c, _ := json.Marshal(p.Text)
				if len(p.Images) > 0 {

					var blocks []aBlock
					if strings.TrimSpace(p.Text) != "" {
						blocks = append(blocks, aBlock{Type: "text", Text: p.Text})
					}
					for _, im := range p.Images {
						blocks = append(blocks, imageBlock(im))
					}
					c, _ = json.Marshal(blocks)
				}
				results = append(results, aBlock{Type: "tool_result", ToolUseID: anthropicOutID(p.CallID), Content: c, IsError: p.IsError, CacheControl: partMark(p.cache)})
			case Thinking:
				if p.sealedBy(sealAnthropic) {
					rest = append(rest, aBlock{Type: "redacted_thinking", sealed: p.Sealed})
				} else if p.Signature != "" {
					rest = append(rest, aBlock{Type: "thinking", Thinking: p.Text, Signature: p.Signature})
				} else if replay && p.Text != "" {
					rest = append(rest, aBlock{Type: "thinking", Thinking: p.Text})
				}
			}
		}
		role := m.Role
		if role != "assistant" {
			role = "user"
		}
		push(role, append(results, rest...))
	}

	msgs = pairToolBlocks(msgs)

	mark := addedMark(r, model)
	var tail, systemMark map[string]string
	if c := r.clientCache; c == nil || c.count == 0 {
		tail, systemMark = mark, mark
	} else {
		if c.tail != "" {
			tail = cacheMark(c.tail)
		}
		if n := len(c.system); n > 0 {

			systemMark = cacheMark(c.system[n-1].TTL)
		}
	}
	if n := len(msgs); n > 0 && tail != nil {
		c := msgs[n-1].Content
		for i := len(c) - 1; i >= 0; i-- {
			if c[i].Type != "thinking" && c[i].Type != "redacted_thinking" {
				c[i].CacheControl = tail
				break
			}
		}
	}

	out := map[string]any{"model": model, "messages": msgs, "stream": r.Stream}
	if r.System != "" {

		out["system"] = []aBlock{{Type: "text", Text: r.System, CacheControl: systemMark}}
	}
	maxTokens := r.MaxTokens
	if maxTokens <= 0 {
		maxTokens = defaultMaxTokens
	}

	think := (r.Thinking || r.Effort != "") && !r.ThinkOff
	if r.ThinkOff {
		out["thinking"] = map[string]any{"type": "disabled"}
	}
	if think && adaptiveOnly(model) {

		out["thinking"] = map[string]any{"type": "adaptive", "display": "summarized"}
		if e := r.Effort; e != "" {
			if e == "xhigh" && noXhigh(model) {
				e = "max"
			}
			out["output_config"] = map[string]any{"effort": e}
		}
	} else if budget := budgetOf(r.Effort); think && (r.MaxTokens <= 0 || r.MaxTokens > 1024) {
		if r.MaxTokens > 0 {

			budget = min(budget, max(1024, maxTokens-1024))
		} else if maxTokens < budget+4096 {
			maxTokens = budget + 4096
		}
		out["thinking"] = map[string]any{"type": "enabled", "budget_tokens": budget}
		if r.Effort != "" && outputEffortAt(host, model) {
			out["output_config"] = map[string]any{"effort": r.Effort}
		}
	} else if r.Temp != nil {
		out["temperature"] = *r.Temp
	} else if r.TopP != nil {
		out["top_p"] = *r.TopP
	}
	if s := r.Format.schema(); len(s) > 0 {
		oc, _ := out["output_config"].(map[string]any)
		if oc == nil {
			oc = map[string]any{}
		}
		oc["format"] = map[string]any{"type": "json_schema", "schema": s}
		out["output_config"] = oc
	}
	out["max_tokens"] = maxTokens
	if len(r.Stop) > 0 {
		out["stop_sequences"] = r.Stop
	}
	if len(r.Metadata) > 0 {
		out["metadata"] = r.Metadata
	}
	if len(r.Safeguards) > 0 && anthropicModel.MatchString(model) {

		out["safeguards"] = r.Safeguards
	}

	rTools := r.Tools
	stubbed := false
	if len(rTools) == 0 && !r.WebSearch {
		for _, n := range historyCallNames(r) {
			rTools = append(rTools, Tool{Name: n, Description: stubToolDescription})
			stubbed = true
		}
	}
	if len(rTools) > 0 || r.WebSearch {
		var tools []map[string]any
		for _, t := range rTools {
			schema := t.Schema
			if len(schema) == 0 {
				schema = json.RawMessage(`{"type":"object","properties":{}}`)
			}
			tool := map[string]any{"name": t.Name, "description": t.Description, "input_schema": schema}
			if t.StrictSpecified {
				tool["strict"] = t.Strict
			}
			tools = append(tools, tool)
		}
		if r.System == "" && len(tools) > 0 && systemMark != nil {
			tools[len(tools)-1]["cache_control"] = systemMark
		}
		if r.WebSearch {
			tools = append(tools, map[string]any{"type": "web_search_20250305", "name": "web_search", "max_uses": 5})
		}
		out["tools"] = tools
		var tc map[string]any
		switch {
		case stubbed || r.ToolChoice == "none":
			tc = map[string]any{"type": "none"}
		case r.ToolChoice == "auto" || r.ToolChoice == "":
			if r.Parallel != nil && !*r.Parallel {
				tc = map[string]any{"type": "auto"}
			}
		case r.ToolChoice == "required":
			tc = map[string]any{"type": "any"}
		case strings.HasPrefix(r.ToolChoice, "name:"):
			tc = map[string]any{"type": "tool", "name": strings.TrimPrefix(r.ToolChoice, "name:")}
		}
		if tc != nil {
			if r.Parallel != nil && !*r.Parallel && tc["type"] != "none" {
				tc["disable_parallel_tool_use"] = true
			}
			out["tool_choice"] = tc
		}
	}
	b, _ := marshalBody(out, "messages")
	return b
}

func pairToolBlocks(msgs []aMessage) []aMessage {
	out := make([]aMessage, 0, len(msgs))
	var pending []string
	open := map[string]bool{}
	answered := map[string]bool{}

	synthetic := func(id string) aBlock {
		c, _ := json.Marshal(interruptedTool)
		return aBlock{Type: "tool_result", ToolUseID: id, Content: c, IsError: true}
	}

	closeExchange := func() {
		var blocks []aBlock
		for _, id := range pending {
			if !answered[id] {
				blocks = append(blocks, synthetic(id))
			}
		}
		if len(blocks) > 0 {
			out = append(out, aMessage{Role: "user", Content: blocks})
		}
		pending, open, answered = nil, map[string]bool{}, map[string]bool{}
	}
	for _, m := range msgs {
		if m.Role == "assistant" {
			closeExchange()
			for _, b := range m.Content {
				if b.Type == "tool_use" {
					pending = append(pending, b.ID)
					open[b.ID] = true
				}
			}
			out = append(out, m)
			continue
		}
		var kept, rest []aBlock
		for _, b := range m.Content {
			if b.Type != "tool_result" {
				rest = append(rest, b)
				continue
			}
			if !open[b.ToolUseID] {

				rest = append(rest, resultSaid(b)...)
				continue
			}
			if answered[b.ToolUseID] {
				continue
			}
			answered[b.ToolUseID] = true
			kept = append(kept, b)
		}
		for _, id := range pending {
			if !answered[id] {
				kept = append(kept, synthetic(id))
			}
		}
		out = append(out, aMessage{Role: "user", Content: append(kept, rest...)})
		pending, open, answered = nil, map[string]bool{}, map[string]bool{}
	}
	closeExchange()
	return out
}

func resultSaid(b aBlock) []aBlock {
	var s string
	if len(b.Content) > 0 && json.Unmarshal(b.Content, &s) == nil {
		if strings.TrimSpace(s) == "" {
			s = "Tool result received."
		}
		return []aBlock{{Type: "text", Text: s}}
	}
	var blocks []aBlock
	if len(b.Content) > 0 && json.Unmarshal(b.Content, &blocks) == nil && len(blocks) > 0 {
		return blocks
	}
	return []aBlock{{Type: "text", Text: "Tool result received."}}
}

type anthropicDecoder struct {
	server map[int]bool
	whole  map[int]bool
}

func (d *anthropicDecoder) decode(data string, emit func(Event)) error {
	var ev struct {
		Type         string `json:"type"`
		Index        int    `json:"index"`
		ContentBlock struct {
			Type  string          `json:"type"`
			Input json.RawMessage `json:"input"`
		} `json:"content_block"`
		Delta struct {
			Type string `json:"type"`
		} `json:"delta"`
	}
	if decodeJSON([]byte(data), &ev) == nil {
		switch ev.Type {
		case "content_block_start":
			d.server[ev.Index] = ev.ContentBlock.Type == "server_tool_use"
			d.whole[ev.Index] = false
			if ev.ContentBlock.Type == "tool_use" && fullInput(ev.ContentBlock.Input) {
				if err := decodeAnthropic(data, emit); err != nil {
					return err
				}
				d.whole[ev.Index] = true
				emit(Event{Kind: KToolArgs, Text: string(ev.ContentBlock.Input)})
				return nil
			}
		case "content_block_delta", "content_block_stop":
			if d.server[ev.Index] {
				return nil
			}
			if d.whole[ev.Index] && ev.Delta.Type == "input_json_delta" {
				return nil
			}
		}
	}
	return decodeAnthropic(data, emit)
}

func fullInput(in json.RawMessage) bool {
	var m map[string]any
	return decodeJSON(in, &m) == nil && len(m) > 0
}

func decodeAnthropic(data string, emit func(Event)) error {
	var ev struct {
		Type    string `json:"type"`
		Message struct {
			ID    string `json:"id"`
			Model string `json:"model"`
			Usage aUsage `json:"usage"`
		} `json:"message"`
		Index        int `json:"index"`
		ContentBlock struct {
			Type string `json:"type"`
			ID   string `json:"id"`
			Name string `json:"name"`
			Text string `json:"text"`

			Thinking  string `json:"thinking"`
			Signature string `json:"signature"`
		} `json:"content_block"`
		Delta struct {
			Type            string `json:"type"`
			Text            string `json:"text"`
			PartialJSON     string `json:"partial_json"`
			Thinking        string `json:"thinking"`
			EstimatedTokens *int   `json:"estimated_tokens"`
			Signature       string `json:"signature"`
			StopReason      string `json:"stop_reason"`

			SafeguardResults json.RawMessage `json:"safeguard_results"`
			StopDetails      json.RawMessage `json:"stop_details"`
		} `json:"delta"`
		Usage aUsage `json:"usage"`
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := decodeJSON([]byte(data), &ev); err != nil {

		if e, ok := carriedError(data); ok {
			emit(e)
		}
		return nil
	}
	switch ev.Type {
	case "message_start":
		emit(Event{Kind: KStart, MsgID: ev.Message.ID, Model: ev.Message.Model, Usage: ev.Message.Usage.usage()})
	case "content_block_start":
		switch ev.ContentBlock.Type {
		case "tool_use":
			emit(Event{Kind: KToolStart, ID: ev.ContentBlock.ID, Name: ev.ContentBlock.Name})
		case "text":
			if ev.ContentBlock.Text != "" {
				emit(Event{Kind: KText, Text: ev.ContentBlock.Text})
			}
		case "thinking":

			emit(Event{Kind: KThinkStart})
			if ev.ContentBlock.Thinking != "" {
				emit(Event{Kind: KThink, Text: ev.ContentBlock.Thinking})
			}
			if ev.ContentBlock.Signature != "" {
				emit(Event{Kind: KSig, Name: sealAnthropic, Text: ev.ContentBlock.Signature})
			}
		case "redacted_thinking":

			var whole struct {
				Block json.RawMessage `json:"content_block"`
			}
			if decodeJSON([]byte(data), &whole) == nil && len(whole.Block) > 0 {
				emit(Event{Kind: KSealed, Name: sealAnthropic, Text: string(whole.Block)})
			}
		}
	case "content_block_delta":
		switch ev.Delta.Type {
		case "text_delta":
			emit(Event{Kind: KText, Text: ev.Delta.Text})
		case "input_json_delta":
			emit(Event{Kind: KToolArgs, Text: ev.Delta.PartialJSON})
		case "thinking_delta":
			emit(Event{Kind: KThink, Text: ev.Delta.Thinking, Estimated: ev.Delta.EstimatedTokens})
		case "signature_delta":
			emit(Event{Kind: KSig, Name: sealAnthropic, Text: ev.Delta.Signature})
		}
	case "message_delta":
		if ev.Delta.StopReason != "" {
			emit(Event{Kind: KStop, Stop: stopFromAnthropic(ev.Delta.StopReason)})
		}
		var review json.RawMessage
		if r := ev.Delta.SafeguardResults; len(r) > 0 && string(r) != "null" {
			review = r
		}
		emit(Event{Kind: KUsage, Usage: ev.Usage.usage(), SafeguardResults: review, StopDetails: stopDetails(ev.Delta.StopDetails)})
	case "error":
		code, status, said := filterRefused(data)
		emit(Event{Kind: KError, Text: cmp.Or(ev.Error.Message, ev.Error.Type, streamErrorText(data)), Code: code, Status: status, Said: said})
	}
	return nil
}

type aUsage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`

	CacheCreation *aCacheCreation `json:"cache_creation,omitempty"`

	CacheUnknown bool `json:"magpie_cache_unknown,omitempty"`

	OutputTokensDetails *aOutputDetails `json:"output_tokens_details,omitempty"`
}

type aCacheCreation struct {
	Ephemeral5m int `json:"ephemeral_5m_input_tokens"`
	Ephemeral1h int `json:"ephemeral_1h_input_tokens"`
}

type aOutputDetails struct {
	ThinkingTokens int `json:"thinking_tokens"`
}

func (u aUsage) usage() Usage {
	out := Usage{Input: u.InputTokens, Output: u.OutputTokens, CacheRead: u.CacheReadInputTokens, CacheWrite: u.CacheCreationInputTokens, cacheUnknown: u.CacheUnknown}
	if c := u.CacheCreation; c != nil {
		out.cacheCreationReported = true
		out.cacheCreationHasCounts = c.Ephemeral5m+c.Ephemeral1h > 0
		out.CacheWrite = max(out.CacheWrite, c.Ephemeral5m+c.Ephemeral1h)
		out.CacheWrite1h = c.Ephemeral1h
	}
	if d := u.OutputTokensDetails; d != nil {
		out.Reasoning = d.ThinkingTokens
	}
	return out
}

func (u Usage) anthropic() aUsage {
	out := aUsage{InputTokens: u.Input, OutputTokens: u.Output, CacheReadInputTokens: u.CacheRead, CacheCreationInputTokens: u.CacheWrite}
	if h := min(u.CacheWrite1h, u.CacheWrite); u.cacheCreationReported || h > 0 {
		out.CacheCreation = &aCacheCreation{Ephemeral5m: u.CacheWrite - h, Ephemeral1h: h}
	}
	if u.Reasoning > 0 {
		out.OutputTokensDetails = &aOutputDetails{ThinkingTokens: u.Reasoning}
	}
	return out
}

func stopFromAnthropic(s string) string {
	switch s {
	case "max_tokens", "model_context_window_exceeded":

		return "length"
	case "tool_use",

		"tool_calls", "function_call":
		return "tool"
	case "length":
		return "length"
	case "refusal", "content_filter":
		return "filter"
	}
	return "stop"
}

func stopToAnthropic(s string) string {
	switch s {
	case "length":
		return "max_tokens"
	case "tool":
		return "tool_use"
	case "filter":
		return "refusal"
	}
	return "end_turn"
}

type anthropicEncoder struct {
	id    string
	w     *sseWriter
	model string
	index int
	open  Kind
	args  bool

	fresh   bool
	started bool
	pinged  time.Time
	col     collector
	usage   map[string]any

	cite  citer
	cited bool
}

func anthropicID(id string) string {
	if id == "" {
		return "msg_" + newID()
	}
	if strings.HasPrefix(id, "msg_") {
		return id
	}
	return "msg_" + strings.TrimPrefix(id, "chatcmpl-")
}

const anthropicIDMark = "mp_"

func anthropicOutID(id string) string {
	if id == "" {
		return id
	}
	return safeCallID(anthropicIDMark, id)
}

func anthropicInID(id string) string {

	if _, salted := unsaltCallID(id); salted {
		return id
	}
	return rawCallID(anthropicIDMark, id)
}

func safeCallID(mark, id string) string {
	if safeIDChars.MatchString(id) && !strings.HasPrefix(id, mark) {
		return id
	}
	return mark + base64.RawURLEncoding.EncodeToString([]byte(id))
}

func rawCallID(mark, id string) string {
	if !strings.HasPrefix(id, mark) || !safeIDChars.MatchString(id) {
		return id
	}
	raw, err := base64.RawURLEncoding.DecodeString(id[len(mark):])
	if err != nil || len(raw) == 0 || !utf8.Valid(raw) || safeCallID(mark, string(raw)) != id {
		return id
	}
	return string(raw)
}

var safeIDChars = lazyre.New(`^[A-Za-z0-9_-]+$`)

func (e *anthropicEncoder) start(ev Event) {
	if e.started {
		return
	}
	e.started = true
	id := anthropicID(ev.MsgID)
	e.id = id
	model := ev.Model
	if model == "" {
		model = e.model
	}
	e.w.event("message_start", map[string]any{"type": "message_start", "message": map[string]any{
		"id": id, "type": "message", "role": "assistant", "model": model, "content": []any{},
		"stop_reason": nil, "stop_sequence": nil, "usage": e.usage}})
}

func (e *anthropicEncoder) close() {
	if e.open == "" {
		return
	}
	if e.open == ToolCall && !e.args {
		e.w.event("content_block_delta", map[string]any{"type": "content_block_delta", "index": e.index,
			"delta": map[string]any{"type": "input_json_delta", "partial_json": "{}"}})
	}
	e.w.event("content_block_stop", map[string]any{"type": "content_block_stop", "index": e.index})
	e.index++
	e.open = ""
}

func (e *anthropicEncoder) openBlock(k Kind, block map[string]any) {
	if e.open == k && k != ToolCall {
		return
	}
	e.close()
	e.args, e.fresh = false, false
	block["type"] = map[Kind]string{Text: "text", Thinking: "thinking", ToolCall: "tool_use"}[k]
	e.w.event("content_block_start", map[string]any{"type": "content_block_start", "index": e.index, "content_block": block})
	e.open = k
}

func (e *anthropicEncoder) thinking() {
	if e.fresh {
		e.close()
		e.fresh = false
	}

	e.openBlock(Thinking, map[string]any{"thinking": "", "signature": ""})
}

func (e *anthropicEncoder) delta(d map[string]any) {
	e.w.event("content_block_delta", map[string]any{"type": "content_block_delta", "index": e.index, "delta": d})
}

func (e *anthropicEncoder) sayCited(text string, cites []map[string]any, tail bool) {
	switch {
	case len(cites) > 0:
		e.close()
		e.openBlock(Text, map[string]any{"text": ""})
		e.cited = true
		for _, c := range cites {
			e.delta(map[string]any{"type": "citations_delta", "citation": c})
		}
	case tail && e.open == Text:
	default:
		if e.cited {
			e.close()
		}
		e.openBlock(Text, map[string]any{"text": ""})
		e.cited = false
	}
	e.delta(map[string]any{"type": "text_delta", "text": text})
}

func (e *anthropicEncoder) event(ev Event) {
	if ev.Kind != KStart && !e.started {
		e.start(Event{})
	}
	switch ev.Kind {
	case KText, KUsage, KStart, KTextSig, KStop, KAlive:
	default:

		e.cite.flush(e.sayCited)
	}
	switch ev.Kind {
	case KStart:
		e.start(ev)
	case KText:
		if ev.Text == "" {
			return
		}
		if e.cite.on() {
			e.cite.feed(ev.Text, e.sayCited)
			break
		}
		e.openBlock(Text, map[string]any{"text": ""})
		e.delta(map[string]any{"type": "text_delta", "text": ev.Text})
	case KThinkStart:

		e.fresh = true
		e.col.add(ev)
		return
	case KThink:
		if ev.Text == "" {
			if ev.Estimated == nil {
				return
			}

			e.thinking()
			e.delta(map[string]any{"type": "thinking_delta", "thinking": "", "estimated_tokens": *ev.Estimated})
			return
		}
		e.thinking()
		d := map[string]any{"type": "thinking_delta", "thinking": ev.Text}
		if ev.Estimated != nil {
			d["estimated_tokens"] = *ev.Estimated
		}
		e.delta(d)
	case KSig:

		if e.open == Thinking || e.fresh {
			e.thinking()
			e.delta(map[string]any{"type": "signature_delta", "signature": ev.Text})
		}
	case KSealed:
		if ev.Name == sealAnthropic {

			e.close()
			e.fresh = false
			e.w.event("content_block_start", map[string]any{"type": "content_block_start", "index": e.index, "content_block": json.RawMessage(ev.Text)})
			e.w.event("content_block_stop", map[string]any{"type": "content_block_stop", "index": e.index})
			e.index++
		}
	case KToolStart:
		id := ev.ID
		if id == "" {
			id = "toolu_" + newID()
		}
		e.openBlock(ToolCall, map[string]any{"id": anthropicOutID(id), "name": ev.Name, "input": map[string]any{}})
	case KToolArgs:
		if e.open == ToolCall && ev.Text != "" {
			e.args = true
			e.delta(map[string]any{"type": "input_json_delta", "partial_json": ev.Text})
		}
	case KSearch:

		e.close()
		id := "srvtoolu_" + newID()
		query, _ := json.Marshal(map[string]string{"query": ev.Text})
		e.w.event("content_block_start", map[string]any{"type": "content_block_start", "index": e.index,
			"content_block": map[string]any{"type": "server_tool_use", "id": id, "name": "web_search", "input": map[string]any{}}})
		e.delta(map[string]any{"type": "input_json_delta", "partial_json": string(query)})
		e.w.event("content_block_stop", map[string]any{"type": "content_block_stop", "index": e.index})
		e.index++
		e.w.event("content_block_start", map[string]any{"type": "content_block_start", "index": e.index,
			"content_block": searchResultBlock(id, ev.Hits)})
		e.cite.hits = append(e.cite.hits, ev.Hits...)
		e.w.event("content_block_stop", map[string]any{"type": "content_block_stop", "index": e.index})
		e.index++
	case KAdvice:

		e.close()
		e.w.event("content_block_start", map[string]any{"type": "content_block_start", "index": e.index,
			"content_block": map[string]any{"type": "server_tool_use", "id": ev.ID, "name": advisorTool, "input": map[string]any{}}})
		e.delta(map[string]any{"type": "input_json_delta", "partial_json": ""})
		e.w.event("content_block_stop", map[string]any{"type": "content_block_stop", "index": e.index})
		e.index++
		e.w.event("content_block_start", map[string]any{"type": "content_block_start", "index": e.index,
			"content_block": adviceBlock(ev.ID, ev.Text, ev.Code)})
		e.w.event("content_block_stop", map[string]any{"type": "content_block_stop", "index": e.index})
		e.index++
	case KError:
		e.close()
		typ := "api_error"
		if ev.Status == http.StatusRequestEntityTooLarge && ev.Code != "context_length_exceeded" {

			typ = "request_too_large"
		}
		failed := map[string]any{"type": typ, "message": ev.Text}
		if ev.Code != "" {
			failed["code"] = ev.Code
		}
		saidError(failed, ev.Said)
		e.w.event("error", map[string]any{"type": "error", "error": failed})
	}
	e.col.add(ev)
}

func (e *anthropicEncoder) finish() {
	if !e.started {
		e.start(Event{})
	}
	e.cite.flush(e.sayCited)
	e.close()
	res := e.col.finish()
	delta := map[string]any{"stop_reason": stopToAnthropic(res.Stop), "stop_sequence": nil}
	if len(res.SafeguardResults) > 0 {
		delta["safeguard_results"] = res.SafeguardResults
	}
	if len(res.StopDetails) > 0 {
		delta["stop_details"] = res.StopDetails
	}
	e.w.event("message_delta", map[string]any{"type": "message_delta",
		"delta": delta,
		"usage": e.usage})
	e.w.event("message_stop", map[string]any{"type": "message_stop"})
}

func renderAnthropic(res Result, model string) []byte {
	content := []any{}
	var cite citer
	for _, p := range res.Parts {
		switch p.Kind {
		case Text:
			if p.Text == "" && p.Signature != "" {
				continue
			}
			if cite.on() {
				content = append(content, citedBlocks(&cite, p.Text)...)
				continue
			}
			content = append(content, map[string]any{"type": "text", "text": p.Text})
		case Thinking:
			switch {
			case p.sealedBy(sealAnthropic):
				content = append(content, p.Sealed)
			case p.Text == "" && p.Signature == "":

			default:
				content = append(content, map[string]any{"type": "thinking", "thinking": p.Text, "signature": p.Signature})
			}
		case ToolCall:
			id := p.ID
			if id == "" {
				id = "toolu_" + newID()
			}
			content = append(content, map[string]any{"type": "tool_use", "id": anthropicOutID(id), "name": p.Name, "input": argsOf(p)})
		case Search:
			id := "srvtoolu_" + newID()
			content = append(content,
				map[string]any{"type": "server_tool_use", "id": id, "name": "web_search", "input": map[string]any{"query": p.Text}},
				searchResultBlock(id, p.Hits))
			cite.hits = append(cite.hits, p.Hits...)
		case Advice:
			content = append(content,
				map[string]any{"type": "server_tool_use", "id": p.ID, "name": advisorTool, "input": map[string]any{}},
				adviceBlock(p.ID, p.Text, p.Name))
		}
	}
	id := anthropicID(res.ID)
	if res.Model != "" {
		model = res.Model
	}
	reply := map[string]any{"id": id, "type": "message", "role": "assistant", "model": model,
		"content": content, "stop_reason": stopToAnthropic(res.Stop), "stop_sequence": nil, "usage": res.Usage.anthropic()}
	if len(res.SafeguardResults) > 0 {
		reply["safeguard_results"] = res.SafeguardResults
	}
	if len(res.StopDetails) > 0 {
		reply["stop_details"] = res.StopDetails
	}
	b, _ := json.Marshal(reply)
	return b
}

func citedBlocks(c *citer, text string) []any {
	var blocks []any
	var open map[string]any
	cited := false
	say := func(t string, cites []map[string]any, tail bool) {
		switch {
		case len(cites) > 0:
			open = map[string]any{"type": "text", "text": t, "citations": cites}
			blocks = append(blocks, open)
			cited = true
			return
		case tail && open != nil, open != nil && !cited:
			open["text"] = open["text"].(string) + t
			return
		}
		open = map[string]any{"type": "text", "text": t}
		blocks = append(blocks, open)
		cited = false
	}
	c.feed(text, say)
	c.flush(say)
	return blocks
}

func searchResultBlock(id string, hits []Hit) map[string]any {
	results := []map[string]any{}
	for _, h := range hits {

		var age any
		if h.PageAge != "" {
			age = h.PageAge
		}
		results = append(results, map[string]any{"type": "web_search_result", "title": h.Title, "url": h.URL,
			"encrypted_content": "", "page_age": age})
	}
	return map[string]any{"type": "web_search_tool_result", "tool_use_id": id, "content": results}
}

var idSeq atomic.Uint32

var idClock = time.Now

func newID() string {
	return fmt.Sprintf("%x%08x", idClock().UnixNano(), idSeq.Add(1))
}

func stopDetails(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	return raw
}

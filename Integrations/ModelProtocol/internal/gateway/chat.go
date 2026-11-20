package gateway

import (
	"cmp"
	"encoding/json"
	"fmt"
	"maps"
	"mime"
	"net"
	"net/http"
	"path"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/tidwall/gjson"

	"codexbridge/modelprotocol/internal/provider"
)

type cToolCall struct {
	Index    *int   `json:"index,omitempty"`
	ID       string `json:"id,omitempty"`
	Type     string `json:"type,omitempty"`
	Function struct {
		Name      string `json:"name,omitempty"`
		Arguments string `json:"arguments,omitempty"`
	} `json:"function"`

	ExtraContent json.RawMessage `json:"extra_content,omitempty"`
}

type cRequest struct {
	Model    string `json:"model"`
	Messages []struct {
		Role             string          `json:"role"`
		Content          json.RawMessage `json:"content"`
		ReasoningContent json.RawMessage `json:"reasoning_content,omitempty"`
		Reasoning        json.RawMessage `json:"reasoning,omitempty"`
		ReasoningDetails json.RawMessage `json:"reasoning_details,omitempty"`
		ToolCalls        []cToolCall     `json:"tool_calls,omitempty"`
		ToolCallID       string          `json:"tool_call_id,omitempty"`
	} `json:"messages"`
	Tools []struct {
		Type     string `json:"type"`
		Function struct {
			Name        string          `json:"name"`
			Description string          `json:"description,omitempty"`
			Parameters  json.RawMessage `json:"parameters,omitempty"`
			Strict      *bool           `json:"strict,omitempty"`
		} `json:"function"`
	} `json:"tools,omitempty"`
	ToolChoice          json.RawMessage `json:"tool_choice,omitempty"`
	WebSearchOptions    json.RawMessage `json:"web_search_options,omitempty"`
	MaxTokens           int             `json:"max_tokens,omitempty"`
	MaxCompletionTokens int             `json:"max_completion_tokens,omitempty"`
	Temperature         *float64        `json:"temperature,omitempty"`
	TopP                *float64        `json:"top_p,omitempty"`
	Stop                json.RawMessage `json:"stop,omitempty"`
	Stream              bool            `json:"stream,omitempty"`
	ReasoningEffort     string          `json:"reasoning_effort,omitempty"`

	Reasoning         json.RawMessage `json:"reasoning,omitempty"`
	OutputConfig      json.RawMessage `json:"output_config,omitempty"`
	Thinking          json.RawMessage `json:"thinking,omitempty"`
	ParallelToolCalls *bool           `json:"parallel_tool_calls,omitempty"`
	ServiceTier       string          `json:"service_tier,omitempty"`
	PromptCacheKey    string          `json:"prompt_cache_key,omitempty"`
	ResponseFormat    json.RawMessage `json:"response_format,omitempty"`

	AccessPrograms json.RawMessage `json:"access_programs,omitempty"`
}

func chatEffort(c *cRequest) string {
	if e := effortOf(c.ReasoningEffort); e != "" || strings.TrimSpace(c.ReasoningEffort) != "" {
		return e
	}
	var o struct {
		Effort string `json:"effort"`
	}
	for _, raw := range []json.RawMessage{c.Reasoning, c.OutputConfig} {
		if len(raw) > 0 && decodeJSON(raw, &o) == nil {
			if e := effortOf(o.Effort); e != "" {
				return e
			}
		}
	}
	var th struct {
		Type   string `json:"type"`
		Budget int    `json:"budget_tokens"`
	}
	if len(c.Thinking) > 0 && decodeJSON(c.Thinking, &th) == nil && th.Type == "enabled" {
		return effortOfBudget(th.Budget)
	}
	return ""
}

func parseChat(body []byte) (*Request, error) { return readChat(body, false) }

func readChat(body []byte, facts bool) (*Request, error) {
	decode := decodeJSON
	if facts {
		decode = decodeJSONView
	}
	body = liftMessageTools(body)
	body = shapeChatTools(body)
	var c cRequest
	if err := decode(body, &c); err != nil {
		return nil, fmt.Errorf("invalid request: %v", err)
	}
	r := &Request{Model: c.Model, MaxTokens: c.MaxCompletionTokens, Temp: c.Temperature, TopP: c.TopP,
		Stream: c.Stream, Effort: chatEffort(&c), Parallel: c.ParallelToolCalls, Fast: c.ServiceTier == "priority" || c.ServiceTier == "ultrafast", Ultrafast: c.ServiceTier == "ultrafast", Tier: c.ServiceTier,
		CacheKey: c.PromptCacheKey, Format: openAIFormat(c.ResponseFormat), AccessPrograms: c.AccessPrograms}
	if r.MaxTokens == 0 {
		r.MaxTokens = c.MaxTokens
	}
	if r.Effort != "" {
		r.Thinking = true
	}
	r.ThinkOff = strings.EqualFold(strings.TrimSpace(c.ReasoningEffort), "none")
	var stop string
	if decodeJSON(c.Stop, &stop) == nil && stop != "" {
		r.Stop = []string{stop}
	} else {
		decodeJSON(c.Stop, &r.Stop)
	}
	var sys []string
	for _, m := range c.Messages {
		switch m.Role {
		case "system", "developer":
			sys = append(sys, stringOrText(m.Content))
			r.systemRaw = append(r.systemRaw, m.Content)
		case "user":
			r.Messages = append(r.Messages, Message{Role: "user", Parts: chatParts(m.Content)})
		case "assistant":
			if facts {
				r.Messages = append(r.Messages, Message{Role: "assistant"})
				continue
			}
			msg := Message{Role: "assistant"}

			if think := reasoningText(map[string]json.RawMessage{
				"reasoning_content": m.ReasoningContent,
				"reasoning":         m.Reasoning,
				"reasoning_details": m.ReasoningDetails,
			}); think != "" {
				msg.Parts = append(msg.Parts, Part{Kind: Thinking, Text: think})
			}
			msg.Parts = append(msg.Parts, chatParts(m.Content)...)
			for _, tc := range m.ToolCalls {
				msg.Parts = append(msg.Parts, Part{Kind: ToolCall, ID: tc.ID, Name: tc.Function.Name, Args: parseArgs(tc.Function.Arguments),
					Signature: googleSignature(tc.ExtraContent)})
			}
			r.Messages = append(r.Messages, msg)
		case "tool":
			if facts {
				r.Messages = append(r.Messages, Message{Role: "user", Parts: []Part{{Kind: ToolResult, CallID: m.ToolCallID}}})
				continue
			}
			out, images, audio := toolOutput(m.Content)
			r.Messages = append(r.Messages, Message{Role: "user", Parts: []Part{{Kind: ToolResult, CallID: m.ToolCallID, Text: out, Images: images, Audio: audio}}})
		}
	}
	r.System = strings.Join(sys, "\n\n")
	r.WebSearch = len(c.WebSearchOptions) > 0 && string(c.WebSearchOptions) != "null"
	for i, t := range c.Tools {
		if strings.HasPrefix(t.Type, "web_search") {
			r.WebSearch = true
		}
		if t.Function.Name == "" {

			if search, kept, ok := chatGoogleTool(gjson.GetBytes(body, "tools."+strconv.Itoa(i))); ok {
				r.WebSearch = r.WebSearch || search
				r.GoogleTools = append(r.GoogleTools, kept...)
				continue
			}
		}
		if t.Type != "" && t.Type != "function" {
			continue
		}
		r.Tools = append(r.Tools, Tool{Name: t.Function.Name, Description: t.Function.Description, Schema: t.Function.Parameters, Strict: t.Function.Strict != nil && *t.Function.Strict, StrictSpecified: t.Function.Strict != nil})
	}
	var tc string
	if decodeJSON(c.ToolChoice, &tc) == nil {
		r.ToolChoice = tc
	} else {
		var o struct {
			Type     string `json:"type"`
			Function struct {
				Name string `json:"name"`
			} `json:"function"`
		}
		if decodeJSON(c.ToolChoice, &o) == nil && o.Function.Name != "" {
			r.ToolChoice = "name:" + o.Function.Name
		}
	}
	return r, nil
}

func chatParts(raw json.RawMessage) []Part {
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
		ImageURL struct {
			URL    string `json:"url"`
			Detail string `json:"detail"`
		} `json:"image_url"`
		File struct {
			FileData string `json:"file_data"`
			FileID   string `json:"file_id"`
			Filename string `json:"filename"`
		} `json:"file"`
		VideoURL struct {
			URL string `json:"url"`
		} `json:"video_url"`
		InputAudio struct {
			Data   string `json:"data"`
			Format string `json:"format"`
		} `json:"input_audio"`

		Data      string `json:"data"`
		MediaType string `json:"mediaType"`
		Filename  string `json:"filename"`
	}
	decodeJSON(raw, &items)
	var out []Part
	for _, it := range items {
		switch it.Type {
		case "text":
			out = append(out, Part{Kind: Text, Text: it.Text})
		case "image_url":
			im := imagePart(it.ImageURL.URL)
			im.Detail = it.ImageURL.Detail
			out = append(out, im)
		case "file":
			if p, ok := chatFile(it.File.FileData, it.File.FileID, it.File.Filename); ok {
				out = append(out, p)
			} else if strings.HasPrefix(strings.ToLower(it.MediaType), "video/") {
				if v, ok := videoPart(it.Data, it.MediaType, it.Filename); ok {
					out = append(out, v)
				}
			}
		case "video_url":

			if v, ok := videoPart(it.VideoURL.URL, "", ""); ok {
				out = append(out, v)
			}
		case "input_audio":

			if it.InputAudio.Data != "" {
				out = append(out, Part{Kind: File, MediaType: audioType(it.InputAudio.Format), Data: it.InputAudio.Data})
			}
		}
	}
	return out
}

func audioType(format string) string {
	f := strings.ToLower(strings.TrimSpace(format))
	switch {
	case f == "":
		return "audio/wav"
	case strings.Contains(f, "/"):
		return f
	case f == "mpeg":
		return "audio/mp3"
	}
	return "audio/" + f
}

func chatFile(data, id, name string) (Part, bool) {
	mt, _, _ := strings.Cut(mime.TypeByExtension(strings.ToLower(path.Ext(name))), ";")
	switch {
	case strings.HasPrefix(data, "data:"):
		if p := imagePart(data); p.Data != "" {
			return Part{Kind: File, MediaType: cmp.Or(p.MediaType, mt, "application/octet-stream"), Data: p.Data}, true
		}
	case data != "":
		return Part{Kind: File, MediaType: cmp.Or(mt, "application/octet-stream"), Data: data}, true
	}
	if id != "" {
		return Part{Kind: File, MediaType: cmp.Or(mt, "application/octet-stream"), URL: id}, true
	}
	return Part{}, false
}

func imagePart(u string) Part {
	if strings.HasPrefix(u, "data:") {
		if meta, data, ok := strings.Cut(strings.TrimPrefix(u, "data:"), ","); ok {
			mt := strings.TrimSuffix(meta, ";base64")
			return Part{Kind: Image, MediaType: mt, Data: data}
		}
	}
	return Part{Kind: Image, URL: u}
}

func chatImage(p Part) map[string]any {
	u := map[string]any{"url": dataURL(p)}
	if d := chatDetail(p.Detail); d != "" {
		u["detail"] = d
	}
	return map[string]any{"type": "image_url", "image_url": u}
}

func chatDetail(detail string) string {
	switch d := strings.ToLower(strings.TrimSpace(detail)); d {
	case "low", "high", "auto":
		return d
	case "original":
		return "high"
	}
	return ""
}

func responsesDetail(detail string) string {
	switch d := strings.ToLower(strings.TrimSpace(detail)); d {
	case "low", "high", "auto", "original":
		return d
	}
	return "auto"
}

func dataURL(p Part) string {
	if p.URL != "" && p.Data == "" {
		return p.URL
	}
	return "data:" + p.MediaType + ";base64," + p.Data
}

var failedAsText = map[string]bool{"devin": true, "qoder": true, "qoder-cn": true}

func chatReplaysReasoning(host, model string) bool {
	return strings.Contains(host, "deepseek") || strings.Contains(strings.ToLower(model), "deepseek") || host == provider.CommandCodePlanID || host == "qoder" || host == "qoder-cn"
}

func joinTexts(content []map[string]any) string {
	if len(content) == 1 {
		return content[0]["text"].(string)
	}
	n := 0
	for _, c := range content {
		n += len(c["text"].(string))
	}
	var b strings.Builder
	b.Grow(n)
	for _, c := range content {
		b.WriteString(c["text"].(string))
	}
	return b.String()
}

func buildChat(r *Request, model, host string, rejectTemp bool) []byte {
	r = responseInstructions(r)
	var msgs []map[string]any
	if r.System != "" {
		msgs = append(msgs, map[string]any{"role": "system", "content": r.System})
	}
	replay := chatReplaysReasoning(host, model)

	inlineThink := strings.HasSuffix(host, "minimax.io") || strings.HasSuffix(host, "minimaxi.com") || strings.HasSuffix(host, "minimax.cn")

	gemini := geminiCompat(host, model)

	names := map[string]string{}
	var seen []map[string]any
	seeLater := func(p Part) {
		if len(p.Images) == 0 {
			return
		}
		of := "tool call " + p.CallID
		if name := names[p.CallID]; name != "" {
			of = name + " (" + of + ")"
		} else if p.Name != "" {
			of = p.Name + " (" + of + ")"
		}
		seen = append(seen, map[string]any{"type": "text", "text": "[From the result of " + of + ":]"})
		for _, im := range p.Images {
			seen = append(seen, chatImage(im))
		}
	}
	showSeen := func() {
		if len(seen) > 0 {
			msgs = append(msgs, map[string]any{"role": "user", "content": seen})
			seen = nil
		}
	}
	turns := joinSplitCalls(r.Messages)

	afterTool := false
	for i, m := range turns {
		if m.Role == "assistant" {
			showSeen()
			am := map[string]any{"role": "assistant"}
			var calls []map[string]any
			var think string
			signed := false
			for _, p := range m.Parts {
				if p.Kind == ToolCall && p.Signature != "" {
					signed = true
				}
			}
			for _, p := range m.Parts {
				switch p.Kind {
				case ToolCall:
					id := p.ID
					if id == "" {
						id = "call_" + newID()
					}
					names[id] = p.Name
					call := map[string]any{"id": id, "type": "function",
						"function": map[string]any{"name": p.Name, "arguments": argsString(p)}}
					if sig := p.Signature; sig != "" && (gemini || r.signer != "" && signerOf(sig) == r.signer) {

						call["extra_content"] = googleExtra(sig)
					} else if gemini && !signed {

						call["extra_content"] = googleExtra(skipSignature)
					}
					calls = append(calls, call)
				case Thinking:
					think += p.Text
				}
			}
			t := text(m.Parts)
			if think != "" && inlineThink && !(r.Resume && i == len(r.Messages)-1) {
				t = "<think>" + think + "</think>\n\n" + t
			}
			if t != "" || len(calls) == 0 {
				am["content"] = t
			}
			if len(calls) > 0 {
				am["tool_calls"] = calls
			}

			if r.Resume && i == len(turns)-1 {
				mode := chatPrefill(host, model)
				switch mode {
				case "prefix":
					am["prefix"] = true
				case "partial":
					am["partial"] = true
				}
				if think != "" && mode != "" {
					am["reasoning_content"] = think
				}
			} else if think != "" && replay {
				am["reasoning_content"] = think
			} else if replay && (len(calls) > 0 || afterTool) {

				am["reasoning_content"] = noReasoning
			}
			afterTool = false
			msgs = append(msgs, am)
			continue
		}
		var content []map[string]any
		plain := true
		flush := func() {
			if len(content) == 0 {
				return
			}
			if len(seen) > 0 {
				content, plain = append(seen, content...), false
				seen = nil
			}
			if plain {
				msgs = append(msgs, map[string]any{"role": "user", "content": joinTexts(content)})
			} else {
				msgs = append(msgs, map[string]any{"role": "user", "content": content})
			}
			content, plain = nil, true
		}

		var tools []map[string]any
		for _, p := range m.Parts {
			switch p.Kind {
			case Text:
				content = append(content, map[string]any{"type": "text", "text": p.Text})
			case File:
				if isVideo(p) && !r.videoOff {
					plain = false
					content = append(content, chatVideo(p))
					break
				}

				content = append(content, map[string]any{"type": "text", "text": attachmentText(p)})
			case Image:
				plain = false
				content = append(content, chatImage(p))
			case ToolResult:
				out := p.Text
				if n := len(p.Images); n > 0 {
					note := fmt.Sprintf("[The tool returned %d images; they follow in the next message.]", n)
					if n == 1 {
						note = "[The tool returned an image; it follows in the next message.]"
					}
					if strings.TrimSpace(out) != "" {
						out += "\n\n"
					}
					out += note
				}
				if p.IsError && failedAsText[host] {
					out = "Error: " + out
				}
				tool := map[string]any{"role": "tool", "tool_call_id": p.CallID, "content": out}
				if p.IsError && host == "cursor" {

					tool["is_error"] = true
				}
				tools = append(tools, tool)
				seeLater(p)
			}
		}
		msgs = append(msgs, tools...)
		afterTool = len(tools) > 0 && len(content) == 0 && len(seen) == 0
		flush()
	}
	showSeen()
	msgs, _ = withoutSilentAssistants(msgs)
	msgs = pairToolMessages(msgs)
	out := map[string]any{"model": model, "messages": msgs, "stream": r.Stream}
	if r.CacheKey != "" {
		out["prompt_cache_key"] = r.CacheKey
	}
	if r.Stream {
		out["stream_options"] = map[string]any{"include_usage": true}
	}

	if r.Fast && host == "cursor" {
		out["service_tier"] = "priority"
	}
	if r.OwnTier && r.Tier != "" {
		out["service_tier"] = r.Tier
	}
	if r.MaxTokens > 0 {
		if provider.OpenAIHost(host) {
			out["max_completion_tokens"] = r.MaxTokens
		} else {
			out["max_tokens"] = r.MaxTokens
		}
	}
	if !rejectTemp {
		if r.Temp != nil {
			out["temperature"] = *r.Temp
		}
		if r.TopP != nil {
			out["top_p"] = *r.TopP
		}
	}
	if len(r.Stop) > 0 {
		out["stop"] = r.Stop
	}
	if r.GeminiCompat {

		if tc := aiStudioThinking(r, model); tc != nil {
			out["extra_body"] = map[string]any{"google": map[string]any{"thinking_config": tc}}
		} else if r.ThinkOff {

			out["reasoning_effort"] = cmp.Or(r.OffLevel, "minimal")
		} else if r.Effort != "" {
			out["reasoning_effort"] = r.Effort
		}
	} else if r.Effort != "" {
		out["reasoning_effort"] = r.Effort
	}
	if len(r.Tools) > 0 {
		var tools []map[string]any
		for _, t := range r.Tools {
			fn := map[string]any{"name": t.Name, "description": t.Description}
			if len(t.Schema) > 0 {
				fn["parameters"] = t.Schema
			}
			if t.StrictSpecified {
				fn["strict"] = t.Strict
			}
			tools = append(tools, map[string]any{"type": "function", "function": fn})
		}
		out["tools"] = tools
		switch {
		case r.ToolChoice == "auto" || r.ToolChoice == "none" || r.ToolChoice == "required":
			out["tool_choice"] = r.ToolChoice
		case strings.HasPrefix(r.ToolChoice, "name:"):
			out["tool_choice"] = map[string]any{"type": "function", "function": map[string]any{"name": strings.TrimPrefix(r.ToolChoice, "name:")}}
		}
		if r.Parallel != nil {
			out["parallel_tool_calls"] = *r.Parallel
		}
	}
	if r.Format != nil {
		out["response_format"] = r.Format.chat()
	}
	if r.WebSearch && host == "openrouter.ai" {

		out["plugins"] = []map[string]any{{"id": "web"}}
	}
	b, _ := marshalBody(out, "messages")
	return b
}

func pairToolMessages(msgs []map[string]any) []map[string]any {
	out := make([]map[string]any, 0, len(msgs))
	var pending []string
	order := map[string]int{}
	answered := map[string]bool{}
	var tools []map[string]any

	flushTools := func() {
		if len(tools) == 0 {
			return
		}
		sort.SliceStable(tools, func(i, j int) bool {
			return order[toolMsgID(tools[i])] < order[toolMsgID(tools[j])]
		})
		out = append(out, tools...)
		tools = nil
	}
	flushPending := func() {
		flushTools()
		for _, id := range pending {
			if !answered[id] {
				out = append(out, map[string]any{"role": "tool", "tool_call_id": id,
					"content": "[The result of this tool call is unavailable: the turn was interrupted.]"})
			}
		}
		pending, order, answered = nil, map[string]int{}, map[string]bool{}
	}

	toolAsUser := func(m map[string]any) {
		text := contentText(m["content"])
		if strings.TrimSpace(text) == "" {
			text = "Tool result received."
		}
		if n := len(out); n > 0 && out[n-1]["role"] == "user" {
			if s, ok := out[n-1]["content"].(string); ok {
				out[n-1]["content"] = s + "\n\n" + text
				return
			}
		}
		out = append(out, map[string]any{"role": "user", "content": text})
	}

	for _, m := range msgs {
		switch m["role"] {
		case "assistant":
			calls, _ := m["tool_calls"].([]map[string]any)
			if len(calls) == 0 {
				if len(pending) > 0 && emptyAssistant(m) {

					continue
				}
				flushPending()
				out = append(out, m)
				continue
			}
			flushPending()
			out = append(out, m)
			for i, c := range calls {
				id, _ := c["id"].(string)
				pending = append(pending, id)
				order[id] = i
			}
		case "tool":
			id := toolMsgID(m)
			if _, ok := order[id]; !ok {

				flushPending()
				toolAsUser(m)
				continue
			}
			if answered[id] {
				continue
			}
			answered[id] = true
			tools = append(tools, m)
		default:
			flushPending()
			out = append(out, m)
		}
	}
	flushPending()
	return out
}

func contentText(c any) string {
	switch c := c.(type) {
	case string:
		return c
	case []any:
		var parts []string
		for _, p := range c {
			if pm, _ := p.(map[string]any); pm != nil {
				if t, _ := pm["text"].(string); t != "" {
					parts = append(parts, t)
				}
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

func toolMsgID(m map[string]any) string {
	id, _ := m["tool_call_id"].(string)
	return id
}

func emptyAssistant(m map[string]any) bool {
	if calls, ok := m["tool_calls"].([]map[string]any); ok && len(calls) > 0 {
		return false
	}
	if s, _ := m["reasoning_content"].(string); strings.TrimSpace(s) != "" {
		return false
	}
	s, _ := m["content"].(string)
	return strings.TrimSpace(s) == ""
}

func silentAssistant(m map[string]any) bool {
	if m["role"] != "assistant" {
		return false
	}
	if m["prefix"] == true || m["partial"] == true || m["function_call"] != nil || m["audio"] != nil {
		return false
	}
	if s, _ := m["refusal"].(string); s != "" {
		return false
	}
	switch c := m["tool_calls"].(type) {
	case []map[string]any:
		if len(c) > 0 {
			return false
		}
	case []any:
		if len(c) > 0 {
			return false
		}
	case nil:
	default:
		return false
	}
	switch c := m["content"].(type) {
	case nil:
		return true
	case string:
		return strings.TrimSpace(c) == ""
	case []any:
		for _, p := range c {
			pm, _ := p.(map[string]any)
			if t, _ := pm["text"].(string); pm == nil || pm["type"] != "text" || strings.TrimSpace(t) != "" {
				return false
			}
		}
		return true
	case []map[string]any:
		for _, pm := range c {
			if t, _ := pm["text"].(string); pm["type"] != "text" || strings.TrimSpace(t) != "" {
				return false
			}
		}
		return true
	}
	return false
}

func withoutSilentAssistants(msgs []map[string]any) ([]map[string]any, bool) {
	if !slices.ContainsFunc(msgs, silentAssistant) {
		return msgs, false
	}
	out := make([]map[string]any, 0, len(msgs))
	dropped := false
	for _, m := range msgs {
		if silentAssistant(m) {
			dropped = true
			continue
		}
		if n := len(out); dropped && n > 0 && m["role"] == "user" && out[n-1]["role"] == "user" {
			if joined, ok := joinedUserContent(out[n-1]["content"], m["content"]); ok {
				prev := maps.Clone(out[n-1])
				prev["content"] = joined
				out[n-1] = prev
				continue
			}
		}
		dropped = false
		out = append(out, m)
	}
	return out, true
}

func joinedUserContent(a, b any) (any, bool) {
	as, aText := a.(string)
	bs, bText := b.(string)
	if aText && bText {
		return as + "\n\n" + bs, true
	}
	parts := func(c any) ([]any, bool) {
		switch c := c.(type) {
		case string:
			if strings.TrimSpace(c) == "" {
				return nil, true
			}
			return []any{map[string]any{"type": "text", "text": c}}, true
		case []any:
			return c, true
		case []map[string]any:
			out := make([]any, len(c))
			for i, p := range c {
				out[i] = p
			}
			return out, true
		}
		return nil, false
	}
	ap, aok := parts(a)
	bp, bok := parts(b)
	if !aok || !bok {
		return nil, false
	}
	return append(slices.Clip(ap), bp...), true
}

const aiStudioHost = "generativelanguage.googleapis.com"

func geminiCompat(host, model string) bool {
	if host == aiStudioHost {
		return true
	}
	if !strings.Contains(strings.ToLower(model), "gemini") {
		return false
	}
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	if host == "localhost" || strings.HasSuffix(host, ".local") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate())
}

func aiStudioThinking(r *Request, model string) map[string]any {
	if !r.Thinking || r.ThinkOff || r.Effort == "none" {
		return nil
	}
	tc := map[string]any{"include_thoughts": true}
	level := r.Effort
	switch level {
	case "xhigh", "max":
		level = "high"
	case "minimal", "low", "medium", "high":
	default:
		return tc
	}
	if strings.Contains(strings.ToLower(model), "gemini-2") {
		tc["thinking_budget"] = map[string]int{"minimal": 1024, "low": 1024, "medium": 8192, "high": 24576}[level]
	} else {
		tc["thinking_level"] = level
	}
	return tc
}

type cUsage struct {
	PromptTokens        int `json:"prompt_tokens"`
	CompletionTokens    int `json:"completion_tokens"`
	TotalTokens         int `json:"total_tokens"`
	PromptTokensDetails *struct {
		CachedTokens     int `json:"cached_tokens"`
		CacheWriteTokens int `json:"cache_write_tokens"`
	} `json:"prompt_tokens_details,omitempty"`
	CompletionTokensDetails *struct {
		ReasoningTokens int `json:"reasoning_tokens"`
	} `json:"completion_tokens_details,omitempty"`

	PromptCacheHitTokens     int `json:"prompt_cache_hit_tokens"`
	CachedTokens             int `json:"cached_tokens"`
	NumCachedTokens          int `json:"num_cached_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`

	Credit *float64 `json:"credit"`

	MagpieDeferred *struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
		CachedTokens     int `json:"cached_tokens"`
		CacheWriteTokens int `json:"cache_write_tokens"`
	} `json:"magpie_deferred,omitempty"`

	MagpieCacheUnknown bool `json:"magpie_cache_unknown"`
}

func (u cUsage) usage() Usage {
	out := Usage{Output: u.CompletionTokens, cacheUnknown: u.MagpieCacheUnknown}
	if d := u.PromptTokensDetails; d != nil {
		out.CacheRead, out.CacheWrite = d.CachedTokens, d.CacheWriteTokens
	}
	for _, n := range []int{u.PromptCacheHitTokens, u.CachedTokens, u.NumCachedTokens} {
		if out.CacheRead == 0 {
			out.CacheRead = n
		}
	}
	whole := true
	if out.CacheRead == 0 && out.CacheWrite == 0 {
		out.CacheRead, out.CacheWrite = u.CacheReadInputTokens, u.CacheCreationInputTokens

		whole = u.PromptTokens >= out.CacheRead+out.CacheWrite
	}
	out.Input = u.PromptTokens
	if whole {
		out.Input = max(u.PromptTokens-out.CacheRead-out.CacheWrite, 0)
	}
	if u.CompletionTokensDetails != nil {
		out.Reasoning = u.CompletionTokensDetails.ReasoningTokens
	}
	if c := u.Credit; c != nil && *c >= 0 {
		out.Credits = c
	}
	if d := u.MagpieDeferred; d != nil && d.PromptTokens+d.CompletionTokens > 0 {
		out.Deferred = &Usage{Input: max(d.PromptTokens-d.CachedTokens-d.CacheWriteTokens, 0), Output: d.CompletionTokens,
			CacheRead: d.CachedTokens, CacheWrite: d.CacheWriteTokens}
	}
	return out
}

func (u Usage) chat() map[string]any {
	in := u.prompt()
	return map[string]any{"prompt_tokens": in, "completion_tokens": u.Output, "total_tokens": in + u.Output,
		"prompt_tokens_details":     map[string]any{"cached_tokens": u.CacheRead, "cache_write_tokens": u.CacheWrite},
		"completion_tokens_details": map[string]any{"reasoning_tokens": u.Reasoning}}
}

type chatDecoder struct {
	started   bool
	tool      int
	toolID    string
	toolWhole jsonWhole
	toolDone  bool
	held      []*heldCall
	choice    string

	lead         string
	thought      bool
	thoughtClose string

	code mdCode
	past bool

	trim bool
}

const leadSpace = " \t\r\n"

var thoughtTags = map[string]string{"<thought>": "</thought>", "<thinking>": "</thinking>", "<think>": "</think>"}

func (d *chatDecoder) text(s string, emit func(Event)) {
	if !d.past && !d.thought {
		d.lead += s
		lead := strings.TrimLeft(d.lead, leadSpace)
		for open := range thoughtTags {
			if len(lead) < len(open) && strings.HasPrefix(open, lead) {
				return
			}
		}
		open := ""
		for o := range thoughtTags {
			if strings.HasPrefix(lead, o) {
				open = o
			}
		}
		if open == "" {
			d.past = true
			s, d.lead = d.lead, ""
			emit(Event{Kind: KText, Text: s})
			return
		}
		s, d.lead, d.thought, d.thoughtClose = strings.TrimPrefix(lead, open), "", true, thoughtTags[open]
	}
	thoughtClose := d.thoughtClose
	if d.thought {
		s = d.lead + s
		d.lead = ""
		if i, keep := d.code.find(s, thoughtClose, false); i >= 0 {
			if i > 0 {
				emit(Event{Kind: KThink, Text: s[:i]})
			}
			d.thought, d.past, d.trim = false, true, true
			s = s[i+len(thoughtClose):]
		} else {

			if t := s[:len(s)-keep]; t != "" {
				emit(Event{Kind: KThink, Text: t})
			}
			d.lead = s[len(s)-keep:]
			return
		}
	}
	if d.trim {
		if s = strings.TrimLeft(s, "\r\n"); s != "" {
			d.trim = false
		}
	}
	if s != "" {
		emit(Event{Kind: KText, Text: s})
	}
}

type mdCode struct {
	span  int
	fence int
	mid   bool
}

func (m *mdCode) find(s, close string, last bool) (at, hold int) {
	for j := 0; j < len(s); {
		switch c := s[j]; {
		case c == '`':
			k := j
			for k < len(s) && s[k] == '`' {
				k++
			}
			if k == len(s) && !last {
				return -1, len(s) - j
			}
			switch n := k - j; {
			case m.fence > 0:
				if !m.mid && n >= m.fence {
					m.fence = 0
				}
			case m.span > 0:
				if n == m.span {
					m.span = 0
				}
			case !m.mid && n >= 3:
				m.fence = n
			default:
				m.span = n
			}
			m.mid = true
			j = k
		case c == '\n':
			m.span, m.mid = 0, false
			j++
		case c == ' ' || c == '\t':
			j++
		case c == '<' && m.span == 0 && m.fence == 0:
			if strings.HasPrefix(s[j:], close) {
				return j, 0
			}
			if !last && strings.HasPrefix(close, s[j:]) {
				return -1, len(s) - j
			}
			m.mid = true
			j++
		default:
			m.mid = true
			j++
		}
	}
	return -1, 0
}

func (d *chatDecoder) markedThought(s string, emit func(Event)) {
	if s == "" {
		return
	}
	tagged := d.thought || d.lead != ""
	if lead := strings.TrimLeft(s, leadSpace); !tagged && !d.past {
		tagged = lead == ""
		for open := range thoughtTags {
			tagged = tagged || strings.HasPrefix(lead, open) || strings.HasPrefix(open, lead)
		}
	}
	if !tagged {
		emit(Event{Kind: KThink, Text: s})
		return
	}
	d.text(s, func(ev Event) {
		if ev.Kind == KText {
			ev.Kind = KThink
		}
		emit(ev)
	})
}

func (d *chatDecoder) end(emit func(Event)) {
	if d.lead == "" {
		return
	}
	k := KText
	if d.thought {
		k = KThink
	}
	emit(Event{Kind: k, Text: d.lead})
	d.lead = ""
}

func (d *chatDecoder) decode(data string, emit func(Event)) error {
	if strings.TrimSpace(data) == "[DONE]" {
		d.giveHeld(emit)
		return nil
	}
	var ch struct {
		ID      string `json:"id"`
		Model   string `json:"model"`
		Choices []struct {
			Index json.RawMessage `json:"index"`
			Delta struct {
				Content          json.RawMessage `json:"content"`
				ReasoningContent string          `json:"reasoning_content"`
				Reasoning        string          `json:"reasoning"`
				ToolCalls        []cToolCall     `json:"tool_calls"`

				ExtraContent struct {
					Google struct {
						Thought bool `json:"thought"`
					} `json:"google"`
				} `json:"extra_content"`
			} `json:"delta"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
		Usage *cUsage `json:"usage"`
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := decodeJSON([]byte(data), &ch); err != nil {

		if e, ok := carriedError(data); ok {
			emit(e)
		}
		return nil
	}
	if ch.Error != nil {
		code, status, said := filterRefused(data)
		emit(Event{Kind: KError, Text: cmp.Or(ch.Error.Message, streamErrorText(data)), Code: code, Status: status, Said: said})
		return nil
	}
	if !d.started {
		d.started, d.tool = true, -1

		var prompt Usage
		if ch.Usage != nil && ch.Usage.PromptTokens > 0 {
			u := ch.Usage.usage()
			prompt = Usage{Input: u.Input, CacheRead: u.CacheRead, CacheWrite: u.CacheWrite}
		}
		emit(Event{Kind: KStart, MsgID: ch.ID, Model: ch.Model, Usage: prompt})
	}
	for _, c := range ch.Choices {

		if index, ok := chatChoiceIndex(c.Index); ok {
			if d.choice == "" {
				d.choice = index
			} else if index != d.choice {
				continue
			}
		}

		t := c.Delta.ReasoningContent
		if t == "" {
			t = c.Delta.Reasoning
		}

		var content string
		if text, think, ok := partsText(c.Delta.Content); ok {
			t += think
			content = text
		} else {
			decodeJSON(c.Delta.Content, &content)
		}
		if t != "" {
			emit(Event{Kind: KThink, Text: t})
			if !d.thought && d.lead == "" {

				d.past = true
			}
		}
		if c.Delta.ExtraContent.Google.Thought {
			d.markedThought(content, emit)
		} else if content != "" {
			d.text(content, emit)
		}
		if len(c.Delta.ToolCalls) > 0 {
			d.end(emit)
		}
		for i, tc := range c.Delta.ToolCalls {
			idx := i
			if tc.Index != nil {
				idx = *tc.Index
			}
			d.toolCall(idx, tc, emit)
		}
		if c.FinishReason != "" {
			d.end(emit)
			d.giveHeld(emit)
			emit(Event{Kind: KStop, Stop: stopFromChat(c.FinishReason)})
		}
	}
	if ch.Usage != nil && (ch.Usage.PromptTokens > 0 || ch.Usage.CompletionTokens > 0 || ch.Usage.MagpieDeferred != nil || ch.Usage.Credit != nil) {
		emit(Event{Kind: KUsage, Usage: ch.Usage.usage()})
	}
	return nil
}

type heldCall struct {
	index    int
	id, sent string
	name     string
	args     strings.Builder
}

func (d *chatDecoder) toolCall(idx int, tc cToolCall, emit func(Event)) {
	args := tc.Function.Arguments
	newID := func(id string) bool { return tc.ID != "" && tc.ID != id }
	for _, h := range slices.Backward(d.held) {
		if h.index == idx {
			if newID(h.id) {
				break
			}
			h.args.WriteString(args)
			return
		}
	}
	if d.tool >= 0 && idx == d.tool && !newID(d.toolID) {
		d.toolArgs(args, emit)
		return
	}

	sent := signedID(tc.ID, googleSignature(tc.ExtraContent))
	if d.tool >= 0 && (!d.toolDone || len(d.held) > 0) {
		h := &heldCall{index: idx, id: tc.ID, sent: sent, name: tc.Function.Name}
		h.args.WriteString(args)
		d.held = append(d.held, h)
		return
	}
	d.tool, d.toolID, d.toolWhole, d.toolDone = idx, tc.ID, jsonWhole{}, false
	emit(Event{Kind: KToolStart, ID: sent, Name: tc.Function.Name})
	d.toolArgs(args, emit)
}

func (d *chatDecoder) toolArgs(args string, emit func(Event)) {
	if args == "" {
		return
	}
	d.toolDone = d.toolWhole.feed(args)
	emit(Event{Kind: KToolArgs, Text: args})
}

func (d *chatDecoder) giveHeld(emit func(Event)) {
	if len(d.held) == 0 {
		return
	}
	slices.SortStableFunc(d.held, func(a, b *heldCall) int { return a.index - b.index })
	for _, h := range d.held {
		emit(Event{Kind: KToolStart, ID: h.sent, Name: h.name})
		if h.args.Len() > 0 {
			emit(Event{Kind: KToolArgs, Text: h.args.String()})
		}
	}
	d.held, d.tool, d.toolID, d.toolWhole, d.toolDone = nil, -1, "", jsonWhole{}, false
}

func chatChoiceIndex(raw json.RawMessage) (string, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", false
	}
	var text string
	if decodeJSON(raw, &text) == nil {
		raw = json.RawMessage(text)
	}
	var n json.Number
	if decodeJSON(raw, &n) != nil {
		return "", false
	}
	index, err := n.Int64()
	if err != nil {
		var f float64
		if decodeJSON(raw, &f) != nil || f < 0 || f != float64(int64(f)) {
			return "", false
		}
		index = int64(f)
	}
	if index < 0 {
		return "", false
	}
	return fmt.Sprint(index), true
}

func stopFromChat(s string) string {
	switch s {
	case "length":
		return "length"
	case "tool_calls", "function_call":
		return "tool"
	case "content_filter", "sensitive":
		return "filter"
	}
	return "stop"
}

func stopToChat(s string) string {
	switch s {
	case "length":
		return "length"
	case "tool":
		return "tool_calls"
	case "filter":
		return "content_filter"
	}
	return "stop"
}

type chatEncoder struct {
	w              *sseWriter
	model          string
	id             string
	created        int64
	started        bool
	tool           int
	col            collector
	includeUsage   bool
	usageAvailable bool
}

func (e *chatEncoder) chunk(delta map[string]any, finish any, usage any) {
	choices := []map[string]any{}
	if delta != nil || finish != nil {
		if delta == nil {
			delta = map[string]any{}
		}
		choices = append(choices, map[string]any{"index": 0, "delta": delta, "finish_reason": finish})
	}
	chunk := map[string]any{"id": e.id, "object": "chat.completion.chunk", "created": e.created,
		"model": e.model, "choices": choices}
	if e.includeUsage {
		chunk["usage"] = usage
	}
	e.w.event("", chunk)
}

func (e *chatEncoder) start(ev Event) {
	if e.started {
		return
	}
	e.started, e.tool = true, -1
	e.id, e.created = ev.MsgID, time.Now().Unix()
	if e.id == "" {
		e.id = "chatcmpl-" + newID()
	}
	if !strings.HasPrefix(e.id, "chatcmpl-") {
		e.id = "chatcmpl-" + e.id
	}
	if ev.Model != "" {
		e.model = ev.Model
	}
	e.chunk(map[string]any{"role": "assistant", "content": ""}, nil, nil)
}

func (e *chatEncoder) event(ev Event) {
	if ev.Kind != KStart && !e.started {
		e.start(Event{})
	}
	switch ev.Kind {
	case KStart:
		e.start(ev)
	case KText:
		if ev.Text != "" {
			e.chunk(map[string]any{"content": ev.Text}, nil, nil)
		}
	case KThink:
		if ev.Text != "" {
			e.chunk(map[string]any{"reasoning_content": ev.Text}, nil, nil)
		}
	case KToolStart:
		e.tool++
		id := ev.ID
		if id == "" {
			id = "call_" + newID()
		}
		e.chunk(map[string]any{"tool_calls": []map[string]any{{"index": e.tool, "id": id, "type": "function",
			"function": map[string]any{"name": ev.Name, "arguments": ""}}}}, nil, nil)
	case KToolArgs:
		if e.tool >= 0 && ev.Text != "" {
			e.chunk(map[string]any{"tool_calls": []map[string]any{{"index": e.tool,
				"function": map[string]any{"arguments": ev.Text}}}}, nil, nil)
		}
	case KError:
		typ := "api_error"
		if ev.Status == http.StatusRequestEntityTooLarge && ev.Code != "context_length_exceeded" {

			typ = "request_too_large"
		}
		failed := map[string]any{"message": ev.Text, "type": typ}
		if ev.Code != "" {
			failed["code"] = ev.Code
		}
		saidError(failed, ev.Said)
		e.w.event("", map[string]any{"error": failed})
	}
	e.col.add(ev)
}

func (e *chatEncoder) finish() {
	if !e.started {
		e.start(Event{})
	}
	res := e.col.finish()
	e.chunk(nil, stopToChat(res.Stop), nil)
	if e.includeUsage && e.usageAvailable {
		e.chunk(nil, nil, res.Usage.chat())
	}
	e.w.event("", "[DONE]")
}

func renderChat(res Result, model string) []byte {
	msg := map[string]any{"role": "assistant", "content": nil}
	var calls []map[string]any
	var think string
	for _, p := range res.Parts {
		switch p.Kind {
		case Text:
			if p.Text == "" && p.Signature != "" {
				continue
			}
			if msg["content"] == nil {
				msg["content"] = p.Text
			} else {
				msg["content"] = msg["content"].(string) + p.Text
			}
		case Thinking:
			think += p.Text
		case ToolCall:
			id := p.ID
			if id == "" {
				id = "call_" + newID()
			}
			calls = append(calls, map[string]any{"id": id, "type": "function",
				"function": map[string]any{"name": p.Name, "arguments": argsString(p)}})
		}
	}
	if len(calls) > 0 {
		msg["tool_calls"] = calls
	}
	if think != "" {
		msg["reasoning_content"] = think
	}
	id := res.ID
	if id == "" {
		id = newID()
	}
	if !strings.HasPrefix(id, "chatcmpl-") {
		id = "chatcmpl-" + id
	}
	if res.Model != "" {
		model = res.Model
	}
	b, _ := json.Marshal(map[string]any{"id": id, "object": "chat.completion", "created": time.Now().Unix(), "model": model,
		"choices": []map[string]any{{"index": 0, "message": msg, "finish_reason": stopToChat(res.Stop)}},
		"usage":   res.Usage.chat()})
	return b
}

func chatGoogleTool(t gjson.Result) (search bool, kept []json.RawMessage, ok bool) {
	var m map[string]json.RawMessage
	if !t.IsObject() || json.Unmarshal([]byte(t.Raw), &m) != nil {
		return false, nil, false
	}
	if typ := snakeToCamel(t.Get("type").String()); typ != "" {
		if !googleSearchTools[typ] && !googleToolNames[typ] {
			return false, nil, false
		}
		v := m[t.Get("type").String()]
		if len(v) == 0 {
			v = m[typ]
		}
		search, kept = googleTools(map[string]json.RawMessage{typ: v}, true)
		return search, kept, true
	}
	delete(m, "type")
	search, kept = googleTools(m, true)
	return search, kept, search || len(kept) > 0
}

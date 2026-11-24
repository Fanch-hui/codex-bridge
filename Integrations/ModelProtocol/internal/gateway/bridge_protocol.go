package gateway

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"

	"codexbridge/modelprotocol/internal/provider"
)

const maxEventBytes = 32 << 20

type BridgeConverter struct {
	requests map[string]*bridgeRequest
}

type bridgeEncoder interface {
	event(Event)
	finish()
}

type bridgeRequest struct {
	from, to        provider.Protocol
	request         *Request
	stream          bool
	plugin          bool
	reasoningScope  string
	decoder         func(string, func(Event)) error
	encoder         bridgeEncoder
	writer          *bridgeWriter
	collector       collector
	line, data      []byte
	collected       int
	responseFields  map[string]json.RawMessage
	includeUsage    bool
	usageInput      bool
	usageOutput     bool
	usageCacheRead  bool
	usageCacheWrite bool
	observedUsage   Usage
	ended, failed   bool
	failure         string
}

type bridgeWriter struct {
	header http.Header
	bytes.Buffer
}

func (w *bridgeWriter) Header() http.Header { return w.header }
func (w *bridgeWriter) WriteHeader(int)     {}
func (w *bridgeWriter) Flush()              {}
func (w *bridgeWriter) take() []byte        { b := bytes.Clone(w.Bytes()); w.Reset(); return b }

func NewBridgeConverter(stateDir string) (*BridgeConverter, error) {
	if !filepath.IsAbs(stateDir) {
		return nil, errors.New("state directory must be absolute")
	}
	sigDir = func() string { return filepath.Join(stateDir, "signatures") }
	return &BridgeConverter{requests: make(map[string]*bridgeRequest)}, nil
}

func bridgeProtocol(s string) (provider.Protocol, error) {
	switch provider.Protocol(s) {
	case provider.Chat, provider.Responses, provider.Anthropic:
		return provider.Protocol(s), nil
	}
	return "", fmt.Errorf("unsupported protocol %q", s)
}

func (c *BridgeConverter) Translate(id, from, to, model, host string, body []byte, plugin bool, scopes ...string) ([]byte, bool, error) {
	if id == "" || model == "" {
		return nil, false, errors.New("request id and model are required")
	}
	if _, ok := c.requests[id]; ok {
		return nil, false, errors.New("request already exists")
	}
	if len(c.requests) >= 40 {
		return nil, false, errors.New("too many active requests")
	}
	if len(body) > maxEventBytes || !json.Valid(body) {
		return nil, false, errors.New("invalid request body")
	}
	f, err := bridgeProtocol(from)
	if err != nil {
		return nil, false, err
	}
	t, err := bridgeProtocol(to)
	if err != nil {
		return nil, false, err
	}
	if f == t {
		return nil, false, errors.New("same-protocol requests use passthrough")
	}
	var reasoningScope string
	if len(scopes) > 1 {
		return nil, false, errors.New("invalid reasoning scope")
	}
	if len(scopes) == 1 {
		reasoningScope = scopes[0]
	}
	if reasoningScope != "" {
		if f != provider.Responses || t != provider.Anthropic || !validReasoningScope(reasoningScope) {
			return nil, false, errors.New("invalid reasoning scope")
		}
	}
	if f == provider.Responses && hasUnportableCurrentImage(body) {
		return nil, false, errors.New("image without URL cannot be translated")
	}
	if f == provider.Responses {
		var fields map[string]json.RawMessage
		if err = json.Unmarshal(body, &fields); err != nil {
			return nil, false, err
		}
		for _, key := range []string{"previous_response_id", "conversation"} {
			if value := bytes.TrimSpace(fields[key]); len(value) > 0 && !bytes.Equal(value, []byte("null")) && !bytes.Equal(value, []byte(`""`)) {
				return nil, false, fmt.Errorf("%s cannot be translated without complete conversation history", key)
			}
		}
		if err := validateResponsesTools(body); err != nil {
			return nil, false, err
		}
	}
	if f == provider.Anthropic {
		if err := validateAnthropicConversion(body); err != nil {
			return nil, false, err
		}
	}
	var req *Request
	switch f {
	case provider.Chat:
		req, err = parseChat(body)
	case provider.Responses:
		req, err = parseResponses(body, reasoningScope)
	case provider.Anthropic:
		req, err = parseAnthropic(body)
	}
	if err != nil {
		return nil, false, err
	}
	req, err = afterParse(f, body, req)
	if err != nil {
		return nil, false, err
	}
	if err = validateBridgeOptions(f, body, req); err != nil {
		return nil, false, err
	}
	if err = validateBridgeSemantics(f, t, body, req, model); err != nil {
		return nil, false, err
	}
	if msg := unportableVideo(t, req); msg != "" {
		return nil, false, errors.New(msg)
	}
	if req.WebSearch && t == provider.Chat && host != "openrouter.ai" {
		return nil, false, errors.New("upstream does not support translated web search")
	}
	if req.Format != nil && t == provider.Anthropic {
		if req.Format.schema() == nil || req.Format.Strict == nil || !*req.Format.Strict {
			return nil, false, errors.New("Anthropic output requires a strict JSON schema")
		}
	}
	for _, msg := range req.Messages {
		for _, part := range msg.Parts {
			if len(part.Audio) > 0 {
				return nil, false, errors.New("upstream cannot preserve tool audio")
			}
			if part.Kind == Image && msg.Role == "assistant" && t == provider.Responses {
				return nil, false, errors.New("upstream cannot preserve assistant images")
			}
			if part.Kind != File {
				continue
			}
			if isVideo(part) && t == provider.Anthropic {
				continue
			}
			if isVideo(part) && t == provider.Chat {
				continue
			}
			if part.MediaType == "application/pdf" && part.Data != "" && (t == provider.Anthropic || (t == provider.Responses && msg.Role != "assistant")) {
				continue
			}
			return nil, false, errors.New("upstream cannot preserve attached file")
		}
	}
	stream := req.Stream
	req.Stream = true
	var out []byte
	switch t {
	case provider.Chat:
		out = buildChat(req, model, host, false)
	case provider.Responses:
		out = buildResponses(req, model, host, false)
	case provider.Anthropic:
		replay := anthropicReplaysThinking(host, model)
		out = anthropicBody(req, model, host, replay)
		sampling := map[string]any{}
		if req.Temp != nil {
			sampling["temperature"] = *req.Temp
		}
		if req.TopP != nil {
			sampling["top_p"] = *req.TopP
		}
		if len(sampling) > 0 {
			out = withFields(out, sampling)
		}
		if replay {
			out = withThinkingOnToolTurns(out)
		}
		if req.Fast && host == "api.anthropic.com" && provider.ClaudeFast(model) {
			out = withFields(out, map[string]any{"speed": "fast"})
		}
	}
	r := &bridgeRequest{from: f, to: t, request: req, stream: stream, plugin: plugin, reasoningScope: reasoningScope}
	if f == provider.Chat {
		var options struct {
			StreamOptions struct {
				IncludeUsage bool `json:"include_usage"`
			} `json:"stream_options"`
		}
		if err := json.Unmarshal(body, &options); err != nil {
			return nil, false, err
		}
		r.includeUsage = options.StreamOptions.IncludeUsage
	}
	if f == provider.Responses {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(body, &fields); err != nil {
			return nil, false, err
		}
		r.responseFields = map[string]json.RawMessage{}
		for _, key := range []string{"parallel_tool_calls", "tool_choice", "tools"} {
			if value := sentRaw(fields[key]); len(value) > 0 {
				r.responseFields[key] = value
			}
		}
	}
	c.requests[id] = r
	return out, stream, nil
}

func validateResponsesTools(body []byte) error {
	var request rRequest
	if err := json.Unmarshal(liftAdditionalTools(body), &request); err != nil {
		return err
	}
	var validate func([]rTool, bool) error
	validate = func(tools []rTool, nested bool) error {
		for _, tool := range tools {
			switch tool.Type {
			case "function":
			case toolSearch:
				if nested || tool.Execution != "client" {
					return errors.New("server-side tool search cannot be translated")
				}
			case "custom":
				if tool.Format != nil && tool.Format.Type != "text" {
					return errors.New("custom tool grammar cannot be preserved by protocol conversion")
				}
			case "namespace":
				if nested {
					return errors.New("nested tool namespaces cannot be translated")
				}
				if err := validate(tool.Tools, true); err != nil {
					return err
				}
			default:
				if !strings.HasPrefix(tool.Type, "web_search") {
					return fmt.Errorf("tool type %q cannot be translated", tool.Type)
				}
			}
		}
		return nil
	}
	return validate(request.Tools, false)
}

func validateBridgeOptions(from provider.Protocol, body []byte, req *Request) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		return err
	}
	if len(sentRaw(fields["tool_choice"])) > 0 && req.ToolChoice == "" {
		return errors.New("tool choice cannot be translated")
	}
	if req.ToolChoice != "" && req.ToolChoice != "auto" && req.ToolChoice != "none" &&
		req.ToolChoice != "required" && !strings.HasPrefix(req.ToolChoice, "name:") {
		return errors.New("tool choice cannot be translated")
	}
	var format json.RawMessage
	switch from {
	case provider.Chat:
		format = sentRaw(fields["response_format"])
	case provider.Responses:
		if text := sentRaw(fields["text"]); len(text) > 0 {
			var options map[string]json.RawMessage
			if err := json.Unmarshal(text, &options); err != nil {
				return errors.New("invalid Responses text options")
			}
			for name, value := range options {
				if name != "format" && len(sentRaw(value)) > 0 {
					return fmt.Errorf("Responses text option %s cannot be translated", name)
				}
			}
			format = sentRaw(options["format"])
		}
	case provider.Anthropic:
		if config := sentRaw(fields["output_config"]); len(config) > 0 {
			var options map[string]json.RawMessage
			if err := json.Unmarshal(config, &options); err != nil {
				return errors.New("invalid Anthropic output options")
			}
			for name, value := range options {
				if name != "format" && name != "effort" && len(sentRaw(value)) > 0 {
					return fmt.Errorf("Anthropic output option %s cannot be translated", name)
				}
			}
			format = sentRaw(options["format"])
		}
	}
	if len(format) == 0 {
		return nil
	}
	var selection struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(format, &selection); err != nil {
		return errors.New("invalid response format")
	}
	if selection.Type == "text" {
		return nil
	}
	if req.Format == nil || selection.Type != req.Format.Type {
		return errors.New("response format cannot be translated")
	}
	return nil
}

func validateAnthropicConversion(body []byte) error {
	var request struct {
		Thinking *struct {
			Type string `json:"type"`
		} `json:"thinking"`
		ContextManagement json.RawMessage `json:"context_management"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		return err
	}
	if request.Thinking != nil && request.Thinking.Type != "disabled" {
		return errors.New("Anthropic thinking requires signed reasoning that this protocol conversion cannot preserve")
	}
	if context := sentRaw(request.ContextManagement); len(context) > 0 {
		var options map[string]json.RawMessage
		if json.Unmarshal(context, &options) != nil || len(options) != 1 {
			return errors.New("Anthropic context management cannot be translated")
		}
		var edits []map[string]json.RawMessage
		if json.Unmarshal(options["edits"], &edits) != nil {
			return errors.New("Anthropic context management cannot be translated")
		}
		for _, edit := range edits {
			if len(edit) != 2 || string(edit["type"]) != `"clear_thinking_20251015"` || string(edit["keep"]) != `"all"` {
				return errors.New("Anthropic context management cannot be translated")
			}
		}
	}
	return nil
}

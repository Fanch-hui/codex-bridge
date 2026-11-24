package gateway

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"codexbridge/modelprotocol/internal/provider"
	"github.com/tidwall/gjson"
)

func (c *BridgeConverter) Begin(id string) error {
	r, ok := c.requests[id]
	if !ok {
		return errors.New("unknown request")
	}
	if r.decoder != nil {
		return errors.New("response already started")
	}
	switch r.to {
	case provider.Chat:
		d := &chatDecoder{past: r.plugin}
		r.decoder = d.decode
	case provider.Responses:
		d := &responsesDecoder{}
		r.decoder = d.decode
	case provider.Anthropic:
		d := &anthropicDecoder{server: map[int]bool{}, whole: map[int]bool{}}
		r.decoder = d.decode
	}
	r.decoder = carryReasoning(r.decoder, r.from, r.to)
	if r.stream {
		r.writer = &bridgeWriter{header: make(http.Header)}
		w := newSSEWriter(r.writer)
		switch r.from {
		case provider.Chat:
			r.encoder = &chatEncoder{w: w, model: r.request.Model, includeUsage: r.includeUsage}
		case provider.Responses:
			r.encoder = &responsesEncoder{w: w, model: r.request.Model, named: r.request.Namespaced, requestFields: r.responseFields, reasoningScope: r.reasoningScope}
		case provider.Anthropic:
			r.encoder = &anthropicEncoder{w: w, model: r.request.Model}
		}
	}
	return nil
}

func (r *bridgeRequest) feedEvent() error {
	if len(r.data) == 0 {
		return nil
	}
	data := string(r.data)
	r.data = nil
	r.observeUsage(data)
	r.ended = r.ended || replyEnds(r.to, data, upstreamStop([]byte(data)))
	var eventErr error
	err := r.decoder(data, func(ev Event) {
		if r.from == provider.Anthropic && (ev.Kind == KThinkStart || ev.Kind == KThink || ev.Kind == KSig || ev.Kind == KSealed) {
			eventErr = errors.New("upstream reasoning cannot be represented as signed Anthropic thinking")
			return
		}
		if ev.Kind == KError {
			r.failed = true
			r.failure = ev.Text
		}
		if r.stream {
			if encoder, ok := r.encoder.(*anthropicEncoder); ok {
				encoder.usage = r.anthropicUsage()
			}
			r.encoder.event(ev)
		} else {
			r.collected += len(ev.Text) + len(ev.Name) + len(ev.ID)
			if r.collected > maxEventBytes {
				eventErr = errors.New("response exceeds limit")
				return
			}
			r.collector.add(ev)
		}
	})
	if err != nil {
		return err
	}
	return eventErr
}

func (r *bridgeRequest) observeUsage(data string) {
	if !strings.Contains(data, `"usage"`) {
		return
	}
	var input, output, usage string
	var cacheRead, cacheWrite []string
	switch r.to {
	case provider.Chat:
		input, output = "usage.prompt_tokens", "usage.completion_tokens"
		usage = "usage"
		cacheRead = []string{"usage.prompt_tokens_details.cached_tokens", "usage.prompt_cache_hit_tokens", "usage.cached_tokens", "usage.num_cached_tokens", "usage.cache_read_input_tokens"}
		cacheWrite = []string{"usage.prompt_tokens_details.cache_write_tokens", "usage.cache_creation_input_tokens"}
	case provider.Responses:
		input, output = "response.usage.input_tokens", "response.usage.output_tokens"
		usage = "response.usage"
		cacheRead = []string{"response.usage.input_tokens_details.cached_tokens"}
		cacheWrite = []string{"response.usage.input_tokens_details.cache_write_tokens"}
	case provider.Anthropic:
		input, output = "message.usage.input_tokens", "usage.output_tokens"
	}
	r.usageInput = r.usageInput || gjson.Get(data, input).Type == gjson.Number
	r.usageOutput = r.usageOutput || gjson.Get(data, output).Type == gjson.Number
	for _, path := range cacheRead {
		r.usageCacheRead = r.usageCacheRead || gjson.Get(data, path).Type == gjson.Number
	}
	for _, path := range cacheWrite {
		r.usageCacheWrite = r.usageCacheWrite || gjson.Get(data, path).Type == gjson.Number
	}
	raw := gjson.Get(data, usage)
	if raw.Type != gjson.JSON {
		return
	}
	switch r.to {
	case provider.Chat:
		var parsed cUsage
		if json.Unmarshal([]byte(raw.Raw), &parsed) == nil {
			r.observedUsage.add(parsed.usage())
		}
	case provider.Responses:
		var parsed rUsage
		if json.Unmarshal([]byte(raw.Raw), &parsed) == nil {
			r.observedUsage.add(parsed.usage())
		}
	}
}

func (r *bridgeRequest) anthropicUsage() map[string]any {
	usage := map[string]any{
		"input_tokens": nil, "output_tokens": nil,
		"cache_read_input_tokens": nil, "cache_creation_input_tokens": nil,
	}
	if r.usageInput {
		usage["input_tokens"] = r.observedUsage.Input
	}
	if r.usageOutput {
		usage["output_tokens"] = r.observedUsage.Output
	}
	if r.usageCacheRead {
		usage["cache_read_input_tokens"] = r.observedUsage.CacheRead
	}
	if r.usageCacheWrite {
		usage["cache_creation_input_tokens"] = r.observedUsage.CacheWrite
	}
	return usage
}

func (r *bridgeRequest) feedLine(line []byte) error {
	line = bytes.TrimSuffix(line, []byte{'\r'})
	if len(line) == 0 {
		return r.feedEvent()
	}
	if line[0] == ':' {
		return nil
	}
	if bytes.HasPrefix(line, []byte("data:")) {
		data := line[5:]
		data = bytes.TrimPrefix(data, []byte{' '})
		if len(r.data) > 0 {
			r.data = append(r.data, '\n')
		}
		if len(r.data)+len(data) > maxEventBytes {
			return errors.New("event exceeds limit")
		}
		r.data = append(r.data, data...)
		return nil
	}
	if data, ok := bareError(line); ok {
		r.data = append(r.data, data...)
		return r.feedEvent()
	}
	return nil
}

func (c *BridgeConverter) Chunk(id string, data []byte) ([]byte, bool, error) {
	r, ok := c.requests[id]
	if !ok || r.decoder == nil {
		return nil, false, errors.New("response not started")
	}
	if r.failed {
		return nil, true, errors.New(r.failure)
	}
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			r.line = append(r.line, data...)
			break
		}
		r.line = append(r.line, data[:i]...)
		data = data[i+1:]
		if len(r.line) > maxEventBytes {
			return nil, false, errors.New("line exceeds limit")
		}
		if err := r.feedLine(r.line); err != nil {
			delete(c.requests, id)
			return nil, false, err
		}
		r.line = nil
		if r.failed {
			break
		}
	}
	if len(r.line) > maxEventBytes {
		return nil, false, errors.New("line exceeds limit")
	}
	if r.stream {
		return r.writer.take(), r.failed, nil
	}
	return nil, r.failed, nil
}

func (c *BridgeConverter) Finish(id string) ([]byte, error) {
	r, ok := c.requests[id]
	if !ok || r.decoder == nil {
		return nil, errors.New("response not started")
	}
	defer delete(c.requests, id)
	if len(r.line) > 0 {
		if err := r.feedLine(r.line); err != nil {
			return nil, err
		}
	}
	if err := r.feedEvent(); err != nil {
		return nil, err
	}
	if r.failed {
		return nil, fmt.Errorf("upstream error: %s", r.failure)
	}
	if !r.ended {
		return nil, errors.New("upstream stream ended before completion")
	}
	if r.stream {
		switch encoder := r.encoder.(type) {
		case *chatEncoder:
			encoder.usageAvailable = r.usageInput && r.usageOutput
		case *responsesEncoder:
			encoder.usageAvailable = r.usageInput && r.usageOutput
		case *anthropicEncoder:
			encoder.usage = r.anthropicUsage()
		}
		r.encoder.finish()
		return r.writer.take(), nil
	}
	result := r.collector.finish()
	switch r.from {
	case provider.Chat:
		response := renderChat(result, r.request.Model)
		if !r.usageInput || !r.usageOutput {
			response = withFields(response, map[string]any{"usage": nil})
		}
		return response, nil
	case provider.Responses:
		response := renderResponses(result, r.request.Model, r.request.Namespaced, r.reasoningScope)
		fields := map[string]any{}
		for key, value := range r.responseFields {
			fields[key] = value
		}
		if !r.usageInput || !r.usageOutput {
			fields["usage"] = nil
		}
		if len(fields) > 0 {
			response = withFields(response, fields)
		}
		return response, nil
	case provider.Anthropic:
		return withFields(renderAnthropic(result, r.request.Model), map[string]any{"usage": r.anthropicUsage()}), nil
	}
	return nil, errors.New("unsupported protocol")
}

func (c *BridgeConverter) Cancel(id string) bool {
	_, ok := c.requests[id]
	delete(c.requests, id)
	return ok
}

func BridgeErrorKind(err error) string {
	if strings.Contains(err.Error(), "before completion") {
		return "incomplete_stream"
	}
	if strings.HasPrefix(err.Error(), "upstream error:") {
		return "upstream_error"
	}
	return "invalid_request"
}

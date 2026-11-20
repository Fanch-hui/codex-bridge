package gateway

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"codexbridge/modelprotocol/internal/provider"
)

// validateBridgeSemantics catches requests whose meaning the destination
// protocol cannot represent. Vendor-specific sampling policy is handled before
// conversion by the gateway.
func validateBridgeSemantics(from, to provider.Protocol, body []byte, req *Request, model string) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		return err
	}
	if from == provider.Chat {
		if err := validateChatSemantics(fields); err != nil {
			return err
		}
	}
	if from == provider.Responses {
		if err := validateResponsesInput(fields["input"]); err != nil {
			return err
		}
	}
	if from == provider.Anthropic {
		if len(sentRaw(fields["top_k"])) > 0 {
			return errors.New("Anthropic top_k cannot be translated")
		}
		if err := validateAnthropicMessages(body); err != nil {
			return err
		}
	}
	if to == provider.Responses && len(req.Stop) > 0 {
		return errors.New("stop sequences cannot be translated to Responses")
	}
	if to == provider.Anthropic {
		if req.Temp != nil && req.TopP != nil {
			return errors.New("temperature and top_p cannot both be translated to Anthropic")
		}
		if (req.Thinking || req.Effort != "") && !req.ThinkOff && !adaptiveOnly(model) && req.MaxTokens > 0 && req.MaxTokens <= 1024 {
			return errors.New("Anthropic thinking requires max_tokens greater than 1024")
		}
	}
	return nil
}

func validateResponsesInput(raw json.RawMessage) error {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return nil
	}
	var items []struct {
		Type string `json:"type"`
		Role string `json:"role"`
	}
	if err := json.Unmarshal(raw, &items); err != nil {
		return errors.New("invalid Responses input")
	}
	for _, item := range items {
		switch item.Type {
		case "message", "":
			switch item.Role {
			case "user", "assistant", "system", "developer":
			default:
				return fmt.Errorf("Responses message role %q cannot be translated", item.Role)
			}
		case "input_file", "configuration_update", "agent_message", "function_call", "function_call_output",
			"custom_tool_call", "custom_tool_call_output", "tool_search_call", "tool_search_output", "reasoning", "additional_tools":
		case "web_search_call":
			return errors.New("Responses web search history cannot be translated")
		default:
			return fmt.Errorf("Responses input item %q cannot be translated", item.Type)
		}
	}
	return nil
}

func validateAnthropicMessages(body []byte) error {
	var request struct {
		Messages []struct {
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
		Tools []struct {
			Type string `json:"type"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		return err
	}
	for _, tool := range request.Tools {
		if tool.Type != "" && tool.Type != "custom" && !strings.HasPrefix(tool.Type, "web_search") {
			return fmt.Errorf("Anthropic tool type %q cannot be translated", tool.Type)
		}
	}
	for _, message := range request.Messages {
		var text string
		if json.Unmarshal(message.Content, &text) == nil {
			continue
		}
		var blocks []struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(message.Content, &blocks); err != nil {
			return errors.New("invalid Anthropic message content")
		}
		for _, block := range blocks {
			switch block.Type {
			case "text", "image", "video", "document", "tool_use", "tool_result", "thinking", "redacted_thinking":
			default:
				return fmt.Errorf("Anthropic content block %q cannot be translated", block.Type)
			}
		}
	}
	return nil
}

func validateChatSemantics(fields map[string]json.RawMessage) error {
	if raw := sentRaw(fields["n"]); len(raw) > 0 {
		var n int
		if json.Unmarshal(raw, &n) != nil || n != 1 {
			return errors.New("multiple Chat completion choices cannot be translated")
		}
	}
	for _, key := range []string{"frequency_penalty", "presence_penalty"} {
		if raw := sentRaw(fields[key]); len(raw) > 0 {
			var n float64
			if json.Unmarshal(raw, &n) != nil || n != 0 {
				return fmt.Errorf("Chat %s cannot be translated", key)
			}
		}
	}
	if raw := sentRaw(fields["logit_bias"]); len(raw) > 0 {
		var bias map[string]json.RawMessage
		if json.Unmarshal(raw, &bias) != nil || len(bias) > 0 {
			return errors.New("Chat logit_bias cannot be translated")
		}
	}
	if raw := sentRaw(fields["logprobs"]); len(raw) > 0 {
		var enabled bool
		if json.Unmarshal(raw, &enabled) != nil || enabled {
			return errors.New("Chat logprobs cannot be translated")
		}
	}
	if raw := sentRaw(fields["top_logprobs"]); len(raw) > 0 {
		var n int
		if json.Unmarshal(raw, &n) != nil || n != 0 {
			return errors.New("Chat top_logprobs cannot be translated")
		}
	}
	if len(sentRaw(fields["seed"])) > 0 {
		return errors.New("Chat seed cannot be translated")
	}
	if raw := sentRaw(fields["stop"]); len(raw) > 0 {
		var single string
		var multiple []string
		if json.Unmarshal(raw, &single) != nil && json.Unmarshal(raw, &multiple) != nil {
			return errors.New("invalid Chat stop sequences")
		}
	}
	return nil
}

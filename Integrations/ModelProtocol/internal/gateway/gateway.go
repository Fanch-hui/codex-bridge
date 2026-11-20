package gateway

import (
	"bytes"

	"encoding/json"

	"fmt"

	"net/http"

	"strings"

	"codexbridge/modelprotocol/internal/lazyre"

	"codexbridge/modelprotocol/internal/provider"
)

var cacheControlField = []byte("cache_control")

const emptyReply = "an empty reply (the model answered nothing; try again)"

func afterParse(proto provider.Protocol, body []byte, req *Request) (*Request, error) {

	unsignCalls(req)

	unreasonCalls(req)
	req.LastIsTurn = proto == provider.Chat || proto == provider.Responses
	if req.ToolChoice == "required" && len(req.Tools) == 0 && !req.WebSearch && requiredAllowlist(proto, body) {
		return nil, fmt.Errorf("required tool choice has no callable tools after filtering")
	}
	return req, nil
}

func requiredAllowlist(proto provider.Protocol, body []byte) bool {
	switch proto {
	case provider.Responses:
		var q struct {
			ToolChoice struct{ Type, Mode string } `json:"tool_choice"`
		}
		return decodeJSON(body, &q) == nil && q.ToolChoice.Type == "allowed_tools" && q.ToolChoice.Mode == "required"
	case provider.Gemini:
		var q struct {
			ToolConfig struct {
				FunctionCallingConfig struct {
					Mode                 string   `json:"mode"`
					AllowedFunctionNames []string `json:"allowedFunctionNames"`
				} `json:"functionCallingConfig"`
			} `json:"toolConfig"`
		}
		return decodeJSON(body, &q) == nil && strings.EqualFold(q.ToolConfig.FunctionCallingConfig.Mode, "ANY") && len(q.ToolConfig.FunctionCallingConfig.AllowedFunctionNames) > 0
	}
	return false
}

type streamEncoder interface {
	event(Event)
	finish()

	keepalive()
}

func withFields(body []byte, fields map[string]any) []byte {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var m map[string]any
	if err := dec.Decode(&m); err != nil {
		return body
	}
	for k, v := range fields {
		m[k] = v
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	if enc.Encode(m) != nil {
		return body
	}
	return bytes.TrimSuffix(out.Bytes(), []byte("\n"))
}

var tooLongRe = lazyre.New(`(?i)context_length_exceeded|prompt is too long|input is too long|(exceeds?|exceeded|over|beyond)( the)?( model'?s?)?( maximum)? context|context (length|limit|window) (exceeded|is exceeded)|context (window )?(is )?full\b|maximum context length|too many (input |prompt )?tokens|上下文(长度)?(超|过长)|超(过|出)(了)?(模型)?(的)?(最大)?上下文` +
	`|input token count.*exceeds the maximum|maximum prompt length is \d|reduce the length of the messages|maximum allowed input length|longer than the model'?s? context length|available context size|greater than the context length|prompt token count of [\d,]+ exceeds the limit|context window exceeds limit|exceeded model token limit|configured context size|prompt too long|prompt exceeds max length|context_window_exceeded|exceeded (max |maximum )?context length|range of input length should be|token limit exceeded|input tokens? (count )?(exceeds?|exceeded) (the )?(max(imum)? )?limit` +
	`|(内容|输入|文本|提示词?|prompt|问题|对话|消息)(内容|文本)?(长度)?\s*(太长|过长|超长)|字数(太多|过多)` +
	`|(内容|输入|文本|提示词?|prompt|问题|对话|消息)[^，。,.;；!！]{0,12}超(过|出)[^，。,.;；!！]{0,12}(长度|token|令牌|字数)` +
	`|(输入|提示词?|prompt)\s*的?\s*(长度|token|令牌|字数)[^，。,.;；!！]{0,8}超(过|出)`)

func tooLong(status int, msg string) bool {
	if status < 400 || status >= 500 || status == http.StatusTooManyRequests {
		return false
	}
	m := strings.ToLower(msg)
	if strings.Contains(m, "max_tokens") || strings.Contains(m, "max_output_tokens") || strings.Contains(m, "max_completion_tokens") {
		return false
	}
	if paceWords.MatchString(msg) {
		return false
	}
	return tooLongRe.MatchString(msg)
}

var paceWords = lazyre.New(`(?i)rate.?limit|per (minute|hour|day)|\bTP[MD]\b|please wait|try again later|throttl|速率|频繁|频率|限流|并发|每(秒|分钟|小时|天|日)|稍后(再试|重试)`)

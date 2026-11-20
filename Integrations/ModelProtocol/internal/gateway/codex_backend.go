package gateway

import (
	"encoding/json"
)

func marshalJSON(v any) ([]byte, error) {
	if b, ok := marshalRaw(v, true); ok {
		return b, nil
	}
	return json.Marshal(v)
}

var openaiItemPrefix = map[string]string{
	"tool_search_call": "tsc_",
	"custom_tool_call": "ctc_",
}

const outputReplay = "output.encrypted_content"

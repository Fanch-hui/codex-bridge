package gateway

import (
	"bytes"
	"encoding/json"
)

func marshalPlain(v any) ([]byte, error) {
	if b, ok := marshalRaw(v, false); ok {
		return b, nil
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

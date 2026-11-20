package gateway

import (
	"encoding/json"
)

type Format struct {
	Type string

	Name, Description string
	Schema            json.RawMessage

	Strict *bool

	told bool
}

const formatName = "response"

func openAIFormat(raw json.RawMessage) *Format {
	var f struct {
		Type        string          `json:"type"`
		Name        string          `json:"name"`
		Description string          `json:"description"`
		Schema      json.RawMessage `json:"schema"`
		Strict      *bool           `json:"strict"`
		JSONSchema  *struct {
			Name        string          `json:"name"`
			Description string          `json:"description"`
			Schema      json.RawMessage `json:"schema"`
			Strict      *bool           `json:"strict"`
		} `json:"json_schema"`
	}
	if json.Unmarshal(raw, &f) != nil {
		return nil
	}
	switch f.Type {
	case "json_object":
		return &Format{Type: "json_object"}
	case "json_schema":
		if js := f.JSONSchema; js != nil {
			f.Name, f.Description, f.Schema, f.Strict = js.Name, js.Description, js.Schema, js.Strict
		}
		if len(sentRaw(f.Schema)) == 0 {

			return &Format{Type: "json_object"}
		}
		if f.Name == "" {
			f.Name = formatName
		}
		return &Format{Type: "json_schema", Name: f.Name, Description: f.Description, Schema: f.Schema, Strict: f.Strict}
	}
	return nil
}

func (f *Format) schema() json.RawMessage {
	if f == nil || f.Type != "json_schema" {
		return nil
	}
	return f.Schema
}

func (f *Format) responses() map[string]any {
	if f.Type != "json_schema" {
		return map[string]any{"type": "json_object"}
	}
	out := map[string]any{"type": "json_schema", "name": f.Name, "schema": f.Schema}
	if f.Description != "" {
		out["description"] = f.Description
	}
	if f.Strict != nil {
		out["strict"] = *f.Strict
	}
	return out
}

func (f *Format) chat() map[string]any {
	if f.Type != "json_schema" {
		return map[string]any{"type": "json_object"}
	}
	js := map[string]any{"name": f.Name, "schema": f.Schema}
	if f.Description != "" {
		js["description"] = f.Description
	}
	if f.Strict != nil {
		js["strict"] = *f.Strict
	}
	return map[string]any{"type": "json_schema", "json_schema": js}
}

func (f *Format) instruction() string {
	if s := f.schema(); len(s) > 0 {
		return "Respond with a single JSON value and nothing else, matching this JSON schema:\n" + string(s) + "."
	}
	return "Respond with a single JSON object and nothing else."
}

func (r *Request) inSystem() *Request {
	if r.Format == nil {
		return r
	}
	q := *r
	q.Format, q.FormatTold = nil, true
	if !r.Format.told {
		q.System = withLine(q.System, r.Format.instruction())
	}
	return &q
}

func withLine(system, s string) string {
	if system != "" {
		system += "\n\n"
	}
	return system + s
}

package gateway

import (
	"encoding/json"
	"errors"
	"strings"

	"codexbridge/modelprotocol/internal/provider"
)

func hasUnportableCurrentImage(body []byte) bool {
	missing := errors.New("current image has no portable source")
	_, err := walkImages(provider.Responses, body, func(im imageAt) (json.RawMessage, error) {
		if im.Current() && im.Src == "" {
			return nil, missing
		}
		return nil, nil
	})
	return err == missing
}

type imageAt struct {
	Src string

	Last, Tool bool

	Block json.RawMessage
}

func (im imageAt) Current() bool { return im.Last && !im.Tool }

func walkImages(proto provider.Protocol, body []byte, swap func(imageAt) (json.RawMessage, error)) ([]byte, error) {
	turnsKey, contentKey := "messages", "content"
	switch proto {
	case provider.Responses:
		turnsKey = "input"
	case provider.Gemini:
		turnsKey, contentKey = "contents", "parts"
	}
	if !anyImageTurn(proto, body, turnsKey, contentKey) {

		return body, nil
	}
	var request map[string]json.RawMessage
	if decodeJSON(body, &request) != nil {
		return body, nil
	}
	var turns []json.RawMessage
	if decodeJSON(request[turnsKey], &turns) != nil {
		return body, nil
	}
	changed := false
	for i, raw := range turns {
		var turn map[string]json.RawMessage
		if decodeJSON(raw, &turn) != nil {
			continue
		}
		key := contentKey
		tool := false
		var kind string
		if proto == provider.Responses {
			decodeJSON(turn["type"], &kind)
			if kind == "function_call_output" {
				key, tool = "output", true
			}
		}
		if proto == provider.Chat {
			decodeJSON(turn["role"], &kind)
			tool = kind == "tool"
		}
		content, swapped, err := swapImageBlocks(proto, turn[key], i == len(turns)-1, tool, swap)
		if err != nil {
			return body, err
		}
		if !swapped {
			continue
		}
		turn[key] = content
		turns[i], _ = json.Marshal(turn)
		changed = true
	}
	if !changed {
		return body, nil
	}
	request[turnsKey], _ = json.Marshal(turns)
	return json.Marshal(request)
}

func anyImageTurn(proto provider.Protocol, body []byte, turnsKey, contentKey string) bool {
	if !jsonValid(body) {
		return false
	}
	raw := trimJSON(body)
	if raw[0] != '{' {
		return false
	}
	found := false
	eachMember(raw, func(key, val []byte) bool {
		if val[0] == '[' && jsonStringIs(key, turnsKey) {
			found = anyImageBlock(proto, val, contentKey)
		}
		return !found
	})
	return found
}

func anyImageBlock(proto provider.Protocol, turns []byte, contentKey string) bool {
	found := false
	eachElement(turns, func(turn []byte) bool {
		if turn[0] != '{' {
			return true
		}
		eachMember(turn, func(key, val []byte) bool {
			if val[0] == '[' && (jsonStringIs(key, contentKey) || (proto == provider.Responses && jsonStringIs(key, "output"))) {
				found = anyImageIn(proto, val)
			}
			return !found
		})
		return !found
	})
	return found
}

func anyImageIn(proto provider.Protocol, blocks []byte) bool {
	kind := "image"
	switch proto {
	case provider.Chat:
		kind = "image_url"
	case provider.Responses:
		kind = "input_image"
	}
	found := false
	eachElement(blocks, func(block []byte) bool {
		if block[0] != '{' {
			return true
		}

		var inner []byte
		toolResult := false
		eachMember(block, func(key, val []byte) bool {
			switch {
			case proto == provider.Gemini && jsonStringIs(key, "functionResponse"):
				if val[0] == '{' {
					eachMember(val, func(k, v []byte) bool {
						if jsonStringIs(k, "parts") {
							inner = v
						}
						return true
					})
				}
			case proto == provider.Gemini:
				found = jsonStringIs(key, "inlineData") || jsonStringIs(key, "fileData")
			case jsonStringIs(key, "type"):
				found = jsonStringIs(val, kind)
				toolResult = toolResult || (proto == provider.Anthropic && jsonStringIs(val, "tool_result"))
			case proto == provider.Anthropic && jsonStringIs(key, "content"):
				inner = val
			}
			return !found
		})
		if !found && len(inner) > 0 && inner[0] == '[' && (proto == provider.Gemini || toolResult) {
			found = anyImageIn(proto, inner)
		}
		return !found
	})
	return found
}

func swapImageBlocks(proto provider.Protocol, raw json.RawMessage, last, tool bool, swap func(imageAt) (json.RawMessage, error)) (json.RawMessage, bool, error) {
	var blocks []json.RawMessage
	if decodeJSON(raw, &blocks) != nil {
		return raw, false, nil
	}
	swapped := false
	for i, rawBlock := range blocks {
		var block map[string]json.RawMessage
		if decodeJSON(rawBlock, &block) != nil {
			continue
		}
		var kind string
		decodeJSON(block["type"], &kind)
		src, isImage := imageSrc(proto, kind, block)
		if isImage {
			out, err := swap(imageAt{Src: src, Last: last, Tool: tool, Block: rawBlock})
			if err != nil {
				return raw, false, err
			}
			if out != nil {
				blocks[i] = out
				swapped = true
			}
			continue
		}

		if proto == provider.Gemini && len(block["functionResponse"]) > 0 {
			var fr map[string]json.RawMessage
			if decodeJSON(block["functionResponse"], &fr) == nil && len(fr["parts"]) > 0 {
				content, nested, err := swapImageBlocks(proto, fr["parts"], last, true, swap)
				if err != nil {
					return raw, false, err
				}
				if nested {
					fr["parts"] = content
					block["functionResponse"], _ = json.Marshal(fr)
					blocks[i], _ = json.Marshal(block)
					swapped = true
				}
			}
		}
		if proto == provider.Anthropic && kind == "tool_result" {
			content, nested, err := swapImageBlocks(proto, block["content"], last, true, swap)
			if err != nil {
				return raw, false, err
			}
			if nested {
				block["content"] = content
				blocks[i], _ = json.Marshal(block)
				swapped = true
			}
		}
	}
	if !swapped {
		return raw, false, nil
	}
	out, _ := json.Marshal(blocks)
	return out, true, nil
}

func imageSrc(proto provider.Protocol, kind string, block map[string]json.RawMessage) (string, bool) {
	switch proto {
	case provider.Chat:
		if kind != "image_url" {
			return "", false
		}
		var url string
		if decodeJSON(block["image_url"], &url) != nil {
			var obj struct {
				URL string `json:"url"`
			}
			decodeJSON(block["image_url"], &obj)
			url = obj.URL
		}
		return url, true
	case provider.Responses:
		if kind != "input_image" {
			return "", false
		}
		var url string
		decodeJSON(block["image_url"], &url)
		return url, true
	case provider.Anthropic:
		if kind != "image" {
			return "", false
		}
		var src struct {
			Type      string `json:"type"`
			MediaType string `json:"media_type"`
			Data      string `json:"data"`
			URL       string `json:"url"`
		}
		decodeJSON(block["source"], &src)
		switch {
		case src.Type == "base64" && src.Data != "":
			return "data:" + src.MediaType + ";base64," + src.Data, true
		case src.Type == "url":
			return src.URL, true
		}
		return "", true
	case provider.Gemini:
		var data struct {
			MimeType string `json:"mimeType"`
			Data     string `json:"data"`
		}
		decodeJSON(block["inlineData"], &data)
		if strings.HasPrefix(data.MimeType, "image/") {
			return "data:" + data.MimeType + ";base64," + data.Data, true
		}
		if len(block["fileData"]) > 0 {
			var file struct {
				MimeType string `json:"mimeType"`
			}
			if decodeJSON(block["fileData"], &file) != nil || file.MimeType == "" || strings.HasPrefix(file.MimeType, "image/") {
				return "", true
			}
		}
	}
	return "", false
}

package gateway

import (
	"cmp"

	"mime"
	"path"
	"slices"
	"strings"

	"codexbridge/modelprotocol/internal/provider"
)

func isVideo(p Part) bool {
	return p.Kind == File && strings.HasPrefix(strings.ToLower(p.MediaType), "video/")
}

func videoPart(src, mediaType, name string) (Part, bool) {
	if src == "" {
		return Part{}, false
	}
	if strings.HasPrefix(src, "data:") {
		p := imagePart(src)
		if p.Data == "" {
			return Part{}, false
		}
		return Part{Kind: File, MediaType: cmp.Or(mediaType, p.MediaType, videoByName(name), "video/mp4"), Data: p.Data}, true
	}
	if strings.Contains(src, "://") {
		at, _, _ := strings.Cut(src, "?")
		return Part{Kind: File, MediaType: cmp.Or(mediaType, videoByName(cmp.Or(name, at)), "video/mp4"), URL: src}, true
	}
	return Part{Kind: File, MediaType: cmp.Or(mediaType, videoByName(name), "video/mp4"), Data: src}, true
}

func videoByName(name string) string {
	mt, _, _ := strings.Cut(mime.TypeByExtension(strings.ToLower(path.Ext(name))), ";")
	if strings.HasPrefix(mt, "video/") {
		return mt
	}
	return ""
}

func currentVideo(r *Request) bool {
	for i := len(r.Messages) - 1; i >= 0; i-- {
		if m := r.Messages[i]; m.Role == "user" {
			return slices.ContainsFunc(m.Parts, isVideo)
		}
	}
	return false
}

func unportableVideo(to provider.Protocol, r *Request) string {
	if to != provider.Responses || !currentVideo(r) {
		return ""
	}
	return "this request gives the model a video, which the Responses API has no way to carry; send it on Chat, Messages or Gemini's API, or send frames as images"
}

func chatVideo(p Part) map[string]any {
	return map[string]any{"type": "video_url", "video_url": map[string]any{"url": dataURL(p)}}
}

func videoBlock(p Part) aBlock {
	b := imageBlock(p)
	b.Type = "video"
	return b
}

func videoFileType(src, name string) string {
	if rest, ok := strings.CutPrefix(src, "data:"); ok {
		mt, _, _ := strings.Cut(rest, ";")
		mt, _, _ = strings.Cut(mt, ",")
		if strings.HasPrefix(strings.ToLower(mt), "video/") {
			return strings.ToLower(mt)
		}
		if mt != "" {
			return ""
		}
	}
	at, _, _ := strings.Cut(src, "?")
	if strings.Contains(src, "://") {
		return cmp.Or(videoByName(name), videoByName(at))
	}
	return videoByName(name)
}

package provider

import (
	"bytes"
	"cmp"

	"encoding/json"

	"fmt"
	"html"

	"net/http"

	"net/url"
	"slices"

	"strings"

	"codexbridge/modelprotocol/internal/lazyre"
)

const BlockedHint = "the provider's network firewall blocked requests from this IP; wait a while, or switch to another network or proxy"

var edgeBlocked = lazyre.New(`(?i)request has been blocked|errors\.aliyun\.com|you have been blocked|used cloudflare to restrict access|error code: 10(0[5-9]|1[0-2]|20)\b`)

func restrictedHinted(b []byte) bool {
	return bytes.Contains(b, []byte(ZCodeRestrictedHint)) || bytes.Contains(b, []byte(WBRestrictedHint))
}

func APIError(b []byte, fallback string) string {
	if edgeBlocked.Match(b) && !restrictedHinted(b) {
		if said, ok := WebPage(b); ok && fallback != "" {
			return fallback + ": " + said + " — " + BlockedHint
		}
		if fallback == "" {
			return BlockedHint
		}
		return fallback + " — " + BlockedHint
	}
	if link, ok := Verification(b); ok {
		return VerifyMessage(apiError(b, fallback), link)
	}
	if cmdGoNoAPI.Match(b) {
		return apiError(b, fallback) + " — " + CommandCodeGoHint
	}
	if harnessOnly.Match(b) && !bytes.Contains(b, []byte(HarnessOnlyHint)) {
		return apiError(b, fallback) + " — " + HarnessOnlyHint
	}
	return apiError(b, fallback)
}

var cmdGoNoAPI = lazyre.New(`(?i)\bGo plan doesn.t include API access`)

const CommandCodeGoHint = "this plan's key requires a compatible provider plugin and cannot be used as a standard API-key provider"

var verifyWords = lazyre.New(`(?i)verify your account|account verification required|` + verifyAdvice)

var verifyLink = lazyre.New(verifyAdvice + `: open (https://[^\s"\\]+) in a browser`)

func Verification(b []byte) (link string, ok bool) {
	var v struct {
		Error struct {
			Details []struct {
				Reason   string         `json:"reason"`
				Metadata map[string]any `json:"metadata"`
				Links    []struct {
					Description string `json:"description"`
					URL         string `json:"url"`
				} `json:"links"`
			} `json:"details"`
		} `json:"error"`
	}
	parsed := json.Unmarshal(b, &v) == nil
	if parsed {
		help, meta := "", ""
		said := func(m map[string]any, k string) string { s, _ := m[k].(string); return s }
		for _, d := range v.Error.Details {
			if d.Reason == "VALIDATION_REQUIRED" {
				ok = true
				meta = cmp.Or(meta, said(d.Metadata, "validation_link"), said(d.Metadata, "validation_url"), said(d.Metadata, "validationUrl"))
			}
			for _, l := range d.Links {
				if !learnMore(l.Description, l.URL) {
					help = cmp.Or(help, l.URL)
				}
			}
		}
		if ok {
			link = cmp.Or(help, meta)
		}
	}
	if !ok && !verifyWords.Match(b) {
		return "", false
	}
	if link == "" {

		words := b
		if parsed {
			words = []byte(apiError(b, ""))
		}
		if m := verifyLink.FindSubmatch(words); m != nil {
			link = string(m[1])
		} else if m := verifyLink.FindSubmatch(b); m != nil {
			link = string(m[1])
		}
	}
	if u, err := url.Parse(link); err != nil || u.Scheme != "https" || u.Host == "" {
		link = ""
	}
	return link, true
}

func learnMore(desc, link string) bool {
	if strings.EqualFold(strings.TrimSpace(desc), "learn more") {
		return true
	}
	u, err := url.Parse(link)
	return err == nil && u.Hostname() == "support.google.com"
}

const verifyAdvice = "this Google account needs to be verified"

func VerifyMessage(said, link string) string {
	said = strings.TrimSpace(said)
	if strings.Contains(said, verifyAdvice) {
		return said
	}
	if link != "" {
		return said + " — " + verifyAdvice + ": open " + link + " in a browser signed in to it, verify it, then try again"
	}
	return said + " — " + verifyAdvice + ": open the Antigravity app (or Gemini CLI) signed in to it and do what it asks, then try again"
}

func apiError(b []byte, fallback string) string {
	var v struct {
		Error   json.RawMessage `json:"error"`
		Message string          `json:"message"`
		Msg     string          `json:"msg"`
		Detail  json.RawMessage `json:"detail"`
		Errors  []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if json.Unmarshal(b, &v) == nil {
		if len(v.Detail) > 0 {
			v.Error = v.Detail
		}
		if len(v.Errors) > 0 && v.Errors[0].Message != "" {
			return v.Errors[0].Message
		}
		var e struct {
			Message string `json:"message"`
			Type    string `json:"type"`
			Code    any    `json:"code"`
			Param   string `json:"param"`
		}
		if json.Unmarshal(v.Error, &e) == nil && e.Message != "" {
			return withErrorFields(e.Message, e.Type, e.Code, e.Param)
		}
		var s string
		if json.Unmarshal(v.Error, &s) == nil && s != "" {
			return s
		}
		if m := cmp.Or(v.Message, v.Msg); m != "" {
			return m
		}
	}

	if said, ok := WebPage(b); ok {
		if fallback == "" {
			return said
		}
		return fallback + ": " + said
	}
	if len(bytes.TrimSpace(b)) == 0 {
		if statusLine(fallback) {
			return fallback + ": " + NoDetails
		}
		return fallback
	}

	s := strings.Join(strings.Fields(QuotedReply(b)), " ")
	if strings.HasPrefix(s, "<") {
		if s = MarkupText(b); s == "" {
			return fallback
		}
	}
	if r := []rune(s); len(r) > 300 {
		s = string(r[:300]) + "…"
	}
	return fallback + ": " + s
}

const NoDetails = "refused with no details (an empty reply, often from a firewall or proxy in front of the API rather than the API itself)"

var pageStart = lazyre.New(`(?i)^<(!doctype\s+html|html[\s>]|head[\s>]|body[\s>]|title[\s>]|meta[\s>])`)

var pageTitle = lazyre.New(`(?is)<title[^>]*>(.*?)</title>`)

func PageTitle(b []byte) string {
	m := pageTitle.FindSubmatch(b)
	if m == nil {
		return ""
	}
	t := strings.Join(strings.Fields(html.UnescapeString(tagRe.ReplaceAllString(string(m[1]), " "))), " ")
	if r := []rune(t); len(r) > 120 {
		t = string(r[:120]) + "…"
	}
	return t
}

var tagRe = lazyre.New(`<[^>]*>`)

func withErrorFields(msg, typ string, code any, param string) string {
	if !statusLine(strings.TrimSpace(msg)) {
		return msg
	}
	var f []string
	c := ""
	if code != nil {
		c = fmt.Sprint(code)
	}
	for _, x := range []string{typ, c, param} {
		if x != "" && !slices.Contains(f, x) {
			f = append(f, x)
		}
	}
	if len(f) == 0 {
		return msg
	}
	return msg + " (" + strings.Join(f, ", ") + ")"
}

func statusLine(s string) bool {
	if len(s) >= 3 && s[0] >= '1' && s[0] <= '5' && s[1] >= '0' && s[1] <= '9' && s[2] >= '0' && s[2] <= '9' && (len(s) == 3 || s[3] == ' ') {
		return true
	}
	for c := 400; c < 600; c++ {
		if t := http.StatusText(c); t != "" && t == s {
			return true
		}
	}
	return false
}

func WebPage(b []byte) (string, bool) {
	t := bytes.TrimLeft(bytes.TrimSpace(b), "\ufeff")
	if !pageStart.Match(t) {
		return "", false
	}
	if title := PageTitle(t); title != "" {
		return "a web page, not an API reply: “" + title + "”", true
	}

	if said := MarkupText(t); said != "" {
		if r := []rune(said); len(r) > 120 {
			said = string(r[:120]) + "…"
		}
		return "a web page, not an API reply: “" + said + "”", true
	}
	return "a web page, not an API reply", true
}

var unshown = lazyre.New(`(?is)<script[^>]*>.*?</script\s*>|<style[^>]*>.*?</style\s*>|<!--.*?-->|<\?.*?\?>|<!doctype[^>]*>`)

func MarkupText(b []byte) string {
	s := unshown.ReplaceAllString(string(b), " ")
	s = strings.Join(strings.Fields(html.UnescapeString(tagRe.ReplaceAllString(s, " "))), " ")
	if r := []rune(s); len(r) > 300 {
		s = string(r[:300]) + "…"
	}
	return s
}

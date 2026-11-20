package gateway

import (
	"encoding/json"

	"strings"
	"time"

	"codexbridge/modelprotocol/internal/catalog"
)

type Kind string

const (
	Text       Kind = "text"
	Image      Kind = "image"
	File       Kind = "file"
	ToolCall   Kind = "tool_call"
	ToolResult Kind = "tool_result"
	Thinking   Kind = "thinking"
	Search     Kind = "web_search"

	Advice Kind = "advisor"
)

type Part struct {
	Kind Kind
	Text string

	MediaType string
	Data      string
	URL       string

	Detail string

	ID   string
	Name string
	Args json.RawMessage

	CallID     string
	IsError    bool
	Images     []Part
	Standalone map[string]any

	Audio []Part

	Loads []string

	Signature string

	SignedBy string

	Sealed   json.RawMessage
	SealedBy string

	Hits []Hit

	cache string

	block bool
}

const (
	sealAnthropic = "anthropic"
	sealResponses = "responses"
)

func (p Part) sealedBy(api string) bool {
	return p.Kind == Thinking && p.SealedBy == api && len(p.Sealed) > 0
}

type Hit struct {
	Title string `json:"title"`
	URL   string `json:"url"`

	PageAge string `json:"page_age,omitempty"`

	Cited string `json:"cited_text,omitempty"`
}

func attachmentText(p Part) string {
	if p.URL != "" {
		return "[attachment " + p.MediaType + ": " + p.URL + "]"
	}
	return "[attachment " + p.MediaType + "]"
}

type Message struct {
	Role  string
	Parts []Part
}

func joinSplitCalls(ms []Message) []Message {
	out := make([]Message, 0, len(ms))
	for _, m := range ms {
		if n := len(out); n > 0 && m.Role == "assistant" && out[n-1].Role == "assistant" && hasCalls(out[n-1].Parts) {
			out[n-1].Parts = append(out[n-1].Parts, m.Parts...)
			continue
		}
		out = append(out, Message{Role: m.Role, Parts: append([]Part(nil), m.Parts...)})
	}
	return out
}

func hasCalls(parts []Part) bool {
	for _, p := range parts {
		if p.Kind == ToolCall {
			return true
		}
	}
	return false
}

type Tool struct {
	Name            string
	Description     string
	Schema          json.RawMessage
	Strict          bool
	StrictSpecified bool

	Deferred bool
}

type Request struct {
	clientCache *clientCache

	cacheTTL string

	askedTTL string

	pickedTTL string

	leanPrompt bool

	appendPrompt bool

	envElsewhere bool

	envInTurns bool

	envDir string

	envUnknown bool

	remoteCaller bool

	instructionsKept bool

	told bool

	replayed bool

	interactive bool

	tuiRefused bool

	unpasted bool

	hourMarks bool

	videoOff bool

	signer string

	draws bool

	subagent bool

	systemParts []string
	systemRaw   []json.RawMessage

	Model      string
	System     string
	Messages   []Message
	Tools      []Tool
	ToolChoice string
	MaxTokens  int
	Temp       *float64
	TopP       *float64
	Stop       []string
	Stream     bool
	Effort     string
	Thinking   bool

	ThinkOff  bool
	Parallel  *bool
	WebSearch bool

	GoogleTools []json.RawMessage

	Advisor string

	WebAccess json.RawMessage
	Fast      bool

	Ultrafast bool

	Tier string

	OwnTier bool

	OwnEffort bool

	CacheKey string

	Include []string

	ClientMetadata json.RawMessage
	Text           json.RawMessage

	AccessPrograms json.RawMessage

	Metadata json.RawMessage

	ImageConfig json.RawMessage

	GenConfig map[string]json.RawMessage

	Safeguards    json.RawMessage
	SafeguardBeta string

	Format *Format

	FormatTold bool

	GeminiCompat bool

	OffLevel string

	Resume bool

	LastIsTurn bool

	Namespaced map[string]nsTool

	LoadedInPlace bool

	CR bool
}

type nsTool struct {
	Namespace, Name string
	Search, Custom  bool
}

type EventKind int

const (
	KStart EventKind = iota
	KText
	KThink
	KSig
	KToolStart
	KToolArgs
	KStop
	KUsage
	KError
	KSearch
	KImage

	KThinkStart

	KSealed

	KTextSig

	KAlive

	KAdvice
)

type Event struct {
	Kind   EventKind
	Status int
	Text   string
	ID     string
	Name   string
	MsgID  string
	Model  string
	Stop   string

	Code             string
	RequestID        string
	Usage            Usage
	Hits             []Hit
	SafeguardResults json.RawMessage

	StopDetails json.RawMessage

	Estimated *int

	Wait time.Duration

	Said json.RawMessage
}

type Usage struct {
	Input      int `json:"input"`
	Output     int `json:"output"`
	CacheRead  int `json:"cache_read"`
	CacheWrite int `json:"cache_write"`

	CacheWrite1h int `json:"cache_write_1h,omitempty"`

	cacheCreationReported bool

	cacheCreationHasCounts bool

	cacheUnknown bool

	searches int

	restart bool

	Reasoning int `json:"reasoning"`

	Served string `json:"served,omitempty"`

	Upstream string `json:"upstream,omitempty"`

	RequestID string `json:"request_id,omitempty"`

	ResponseID string `json:"response_id,omitempty"`
	ErrType    string `json:"err_type,omitempty"`

	Stop string `json:"stop,omitempty"`

	Tier string `json:"tier,omitempty"`

	Deferred *Usage `json:"deferred,omitempty"`

	Credits *float64 `json:"credits,omitempty"`
}

func (u Usage) prompt() int {
	return u.Input + u.CacheRead + u.CacheWrite
}

func (u *Usage) add(v Usage) {
	if v.restart {
		u.Input, u.CacheRead, u.CacheWrite, u.CacheWrite1h = v.Input, v.CacheRead, v.CacheWrite, v.CacheWrite1h
	}
	if v.Input > 0 {
		u.Input = v.Input
	}
	if v.Output > 0 {
		u.Output = v.Output
	}
	if v.CacheRead > 0 {
		u.CacheRead = v.CacheRead
	}
	if v.CacheWrite > 0 {
		u.CacheWrite = v.CacheWrite
	}
	if v.CacheWrite1h > 0 {
		u.CacheWrite1h = v.CacheWrite1h
	}
	u.cacheCreationReported = u.cacheCreationReported || v.cacheCreationReported
	u.cacheUnknown = u.cacheUnknown || v.cacheUnknown
	u.searches = max(u.searches, v.searches)
	if v.Reasoning > 0 {
		u.Reasoning = v.Reasoning
	}
	if v.Served != "" {
		u.Served = v.Served
	}
	if v.Upstream != "" {
		u.Upstream = v.Upstream
	}
	if v.Tier != "" {
		u.Tier = v.Tier
	}
	if v.RequestID != "" {
		u.RequestID = v.RequestID
	}
	if v.ResponseID != "" {
		u.ResponseID = v.ResponseID
	}
	if v.ErrType != "" {
		u.ErrType = v.ErrType
	}
	if v.Stop != "" {
		u.Stop = v.Stop
	}
	if v.Deferred != nil {
		u.Deferred = v.Deferred
	}
	if v.Credits != nil {
		u.Credits = v.Credits
	}
}

type Result struct {
	ID               string
	Model            string
	Parts            []Part
	Stop             string
	Usage            Usage
	SafeguardResults json.RawMessage
	StopDetails      json.RawMessage
}

type collector struct {
	res  Result
	args strings.Builder

	text   strings.Builder
	textAt int

	fresh bool
	err   string

	errStatus int
	errCode   string
	errSaid   json.RawMessage
}

func (c *collector) last(k Kind) *Part {
	if n := len(c.res.Parts); n > 0 && c.res.Parts[n-1].Kind == k {
		return &c.res.Parts[n-1]
	}
	return nil
}

func (c *collector) open() *Part {
	if c.fresh {
		return nil
	}
	if p := c.last(Thinking); p != nil && len(p.Sealed) == 0 {
		return p
	}
	return nil
}

func (c *collector) grow(i int, s string) {
	if c.textAt != i+1 {
		c.flush()
		c.text.WriteString(c.res.Parts[i].Text)
		c.textAt = i + 1
	}
	c.text.WriteString(s)
}

func (c *collector) flush() {
	if c.textAt > 0 {
		c.res.Parts[c.textAt-1].Text = c.text.String()
		c.text = strings.Builder{}
		c.textAt = 0
	}
}

func (c *collector) closeTool() {
	if p := c.last(ToolCall); p != nil && p.Args == nil {
		s := strings.TrimSpace(c.args.String())
		if s == "" {
			s = "{}"
		}
		p.Args = json.RawMessage(s)
		c.args.Reset()
	}
}

func (c *collector) add(ev Event) {
	if len(ev.SafeguardResults) > 0 {
		c.res.SafeguardResults = ev.SafeguardResults
	}
	if len(ev.StopDetails) > 0 {
		c.res.StopDetails = ev.StopDetails
	}
	switch ev.Kind {
	case KStart:
		c.res.ID, c.res.Model = ev.MsgID, ev.Model
		c.res.Usage.add(ev.Usage)
	case KText:
		if p := c.last(Text); p != nil {
			c.grow(len(c.res.Parts)-1, ev.Text)
		} else {
			c.closeTool()
			c.res.Parts = append(c.res.Parts, Part{Kind: Text, Text: ev.Text})
		}
	case KThinkStart:
		c.fresh = true
		return
	case KThink:
		if p := c.open(); p != nil {
			c.grow(len(c.res.Parts)-1, ev.Text)
		} else {
			c.closeTool()
			c.res.Parts = append(c.res.Parts, Part{Kind: Thinking, Text: ev.Text})
		}
	case KSig:

		if p := c.open(); p != nil {
			p.Signature += ev.Text
			if ev.Name != "" {
				p.SignedBy = ev.Name
			}
		} else if c.fresh {
			c.closeTool()
			c.res.Parts = append(c.res.Parts, Part{Kind: Thinking, Signature: ev.Text, SignedBy: ev.Name})
		}
	case KSealed:

		if p := c.open(); p != nil && ev.Name == sealResponses && p.Signature == "" {
			p.Sealed, p.SealedBy = json.RawMessage(ev.Text), ev.Name
		} else {
			c.closeTool()
			c.res.Parts = append(c.res.Parts, Part{Kind: Thinking, Sealed: json.RawMessage(ev.Text), SealedBy: ev.Name})
		}
	case KTextSig:
		if p := c.last(Text); p != nil && p.Signature == "" {
			p.Signature = ev.Text
		} else {
			c.closeTool()
			c.res.Parts = append(c.res.Parts, Part{Kind: Text, Signature: ev.Text})
		}
	case KToolStart:
		c.closeTool()
		c.res.Parts = append(c.res.Parts, Part{Kind: ToolCall, ID: ev.ID, Name: ev.Name})
	case KToolArgs:
		c.args.WriteString(ev.Text)
	case KStop:
		c.closeTool()
		c.res.Stop = ev.Stop
	case KUsage:
		c.res.Usage.add(ev.Usage)
		c.res.Usage.add(Usage{RequestID: ev.RequestID})
		if ev.Model != "" {
			c.res.Model = ev.Model
		}
	case KError:
		c.err, c.errStatus, c.errCode, c.errSaid = ev.Text, ev.Status, ev.Code, ev.Said
	case KSearch:
		c.closeTool()
		c.res.Parts = append(c.res.Parts, Part{Kind: Search, Text: ev.Text, Hits: ev.Hits})
	case KImage:
		c.closeTool()
		c.res.Parts = append(c.res.Parts, Part{Kind: Image, MediaType: ev.Name, Data: ev.Text})
	case KAdvice:
		c.closeTool()
		c.res.Parts = append(c.res.Parts, Part{Kind: Advice, ID: ev.ID, Text: ev.Text, Name: ev.Code})
	}
	switch ev.Kind {
	case KStart, KUsage, KError, KAlive:
	default:

		c.fresh = false
	}
}

func (c *collector) finish() Result {
	c.flush()
	c.closeTool()

	if c.res.Stop == "" || c.res.Stop == "stop" {
		c.res.Stop = "stop"
		for _, p := range c.res.Parts {
			if p.Kind == ToolCall {
				c.res.Stop = "tool"
			}
		}
	}
	return c.res
}

func argsOf(p Part) json.RawMessage {
	if len(p.Args) == 0 || strings.TrimSpace(string(p.Args)) == "" {
		return json.RawMessage("{}")
	}
	return p.Args
}

func argsString(p Part) string { return string(argsOf(p)) }

func parseArgs(s string) json.RawMessage {
	s = strings.TrimSpace(s)
	if s == "" {
		return json.RawMessage("{}")
	}
	if json.Valid([]byte(s)) && strings.HasPrefix(s, "{") {
		return json.RawMessage(s)
	}
	b, _ := json.Marshal(map[string]string{"input": s})
	return b
}

func text(parts []Part) string {
	var b strings.Builder
	for _, p := range parts {
		if p.Kind == Text {
			b.WriteString(p.Text)
		}
	}
	return b.String()
}

func stringOrText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if decodeJSON(raw, &s) == nil {
		return s
	}
	var blocks []struct {
		Type     string `json:"type"`
		Text     string `json:"text"`
		ToolName string `json:"tool_name"`
	}
	if decodeJSON(raw, &blocks) == nil {
		var b strings.Builder
		for _, x := range blocks {
			switch x.Type {
			case "text", "input_text", "output_text":
				b.WriteString(x.Text)
			case "tool_reference":

				if b.Len() > 0 {
					b.WriteString("\n")
				}
				b.WriteString(toolLoadedText(x.ToolName))
			}
		}
		return b.String()
	}
	return ""
}

func toolOutput(raw json.RawMessage) (string, []Part, []Part) {
	text := stringOrText(raw)
	var blocks []struct {
		Type   string `json:"type"`
		Source *struct {
			MediaType string `json:"media_type"`
			Data      string `json:"data"`
			URL       string `json:"url"`
		} `json:"source"`
		ImageURL   json.RawMessage `json:"image_url"`
		Detail     string          `json:"detail"`
		InputAudio struct {
			Data   string `json:"data"`
			Format string `json:"format"`
		} `json:"input_audio"`
	}
	if len(raw) == 0 || raw[0] != '[' || decodeJSON(raw, &blocks) != nil {
		return text, nil, nil
	}
	var images, audio []Part
	for _, b := range blocks {
		switch b.Type {
		case "image":
			if s := b.Source; s != nil && s.Data != "" {
				images = append(images, Part{Kind: Image, MediaType: s.MediaType, Data: s.Data})
			} else if s != nil && s.URL != "" {
				images = append(images, Part{Kind: Image, URL: s.URL})
			}
		case "input_image", "image_url":
			var u string
			detail := b.Detail
			if decodeJSON(b.ImageURL, &u) != nil {
				var o struct {
					URL    string `json:"url"`
					Detail string `json:"detail"`
				}
				decodeJSON(b.ImageURL, &o)
				u, detail = o.URL, o.Detail
			}
			if u != "" {
				im := imagePart(u)
				im.Detail = detail
				images = append(images, im)
			}
		case "input_audio":

			if b.InputAudio.Data != "" {
				audio = append(audio, Part{Kind: File, MediaType: audioType(b.InputAudio.Format), Data: b.InputAudio.Data})
			}
		}
	}
	for _, a := range audio {
		if text != "" {
			text += "\n"
		}
		text += attachmentText(a)
	}
	return text, images, audio
}

func effortOf(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "minimal", "none":
		return "low"
	case "low", "medium", "high", "xhigh", "max":
		return strings.ToLower(s)
	case "ultra":
		return "max"
	}

	if l, ok := catalog.EffortAliases[strings.ToLower(strings.TrimSpace(s))]; ok {
		return l
	}
	return ""
}

func budgetOf(effort string) int {
	switch effort {
	case "low":
		return 4096
	case "medium":
		return 10000
	case "high":
		return 24000
	case "xhigh", "max":
		return 32000
	}
	return 10000
}

func effortOfBudget(n int) string {
	switch {
	case n <= 0:
		return ""
	case n <= 4096:
		return "low"
	case n <= 12000:
		return "medium"
	case n <= 24000:
		return "high"
	}
	return "xhigh"
}

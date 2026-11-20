package redact

import (
	"regexp"
	"strings"
	"sync"

	"codexbridge/modelprotocol/internal/lazyre"
)

type Rule struct {
	Kind   string `json:"kind"`
	Prefix string `json:"prefix,omitempty"`

	Regex string `json:"regex,omitempty"`
}

const (
	MaxRules     = 32
	maxKind      = 24
	maxPrefix    = 64
	minPrefix    = 3
	maxRegex     = 300
	prefixTail   = `[A-Za-z0-9_\-]{8,}`
	customKind   = "CUSTOM"
	minCustomLen = 4
)

func RuleKind(kind string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(strings.TrimSpace(kind)) {
		switch {
		case r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_':
			b.WriteRune(r)
		case r == ' ' || r == '-' || r == '.':
			b.WriteByte('_')
		}
	}
	k := strings.Trim(b.String(), "_")
	if k == "" {
		return customKind
	}
	if k[0] < 'A' || k[0] > 'Z' {
		k = customKind + "_" + k
	}
	if len(k) > maxKind {
		k = strings.TrimRight(k[:maxKind], "_")
	}
	return k
}

func (r Rule) compile() (*regexp.Regexp, error) {
	if r.Prefix != "" {
		return regexp.Compile(regexp.QuoteMeta(r.Prefix) + prefixTail)
	}
	return regexp.Compile(r.Regex)
}

var compiled sync.Map

func customRules(in []Rule) []rule {
	var out []rule
	for _, r := range in {
		if strings.TrimSpace(r.Prefix) == "" && strings.TrimSpace(r.Regex) == "" || len(r.Regex) > maxRegex {
			continue
		}
		v, ok := compiled.Load(r)
		if !ok {
			re, err := r.compile()
			if err != nil || re.MatchString("") {
				re = nil
			}
			v, _ = compiled.LoadOrStore(r, re)
		}
		re := v.(*regexp.Regexp)
		if re == nil {
			continue
		}
		c := rule{kind: RuleKind(r.Kind), yours: true, re: lazyre.Of(re), ok: func(v string) bool { return len(v) >= minCustomLen }}
		if r.Prefix != "" {
			c.markers = []string{r.Prefix}
		}
		out = append(out, c)
	}
	return out
}

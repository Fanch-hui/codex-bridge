package redact

import (
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"codexbridge/modelprotocol/internal/lazyre"
)

const dateSep = `(?:[ \t]*[-/.、／－][ \t]*|[ \t])`

var (
	dateYMD   = lazyre.New(`^(\d{4})` + dateSep + `(\d{1,2})` + dateSep + `(\d{1,2})\.?$`)
	dateCJK   = lazyre.New(`^(\d{4})[ \t]*[年년][ \t]*(\d{1,2})[ \t]*[月월][ \t]*(\d{1,2})[ \t]*[日号號일]?$`)
	dateDMY   = lazyre.New(`^(\d{1,2})` + dateSep + `(\d{1,2})` + dateSep + `(\d{4})$`)
	dateNameF = lazyre.New(`^([A-Za-z]+)\.?[ \t]+(\d{1,2})(?:st|nd|rd|th)?,?[ \t]+(\d{4})$`)
	dateNameB = lazyre.New(`^(\d{1,2})(?:st|nd|rd|th)?(?:[ \t]+|-)([A-Za-z]+)\.?,?(?:[ \t]+|-)(\d{4})$`)
)

var monthNames = []string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

func monthOf(name string) int {
	l := strings.ToLower(name)
	if l == "sept" {
		return 9
	}
	for i, m := range monthNames {
		ml := strings.ToLower(m)
		if l == ml || len(l) == 3 && strings.HasPrefix(ml, l) {
			return i + 1
		}
	}
	return 0
}

func realDate(y, m, d int) bool {
	if y < 1000 || y > 2999 || m < 1 || m > 12 || d < 1 {
		return false
	}
	t := time.Date(y, time.Month(m), d, 0, 0, 0, 0, time.UTC)
	return t.Day() == d && int(t.Month()) == m
}

func parseDateWord(w string) (y, m, d int, ok bool) {
	n := func(s string) int { v, _ := strconv.Atoi(s); return v }
	if g := dateYMD.FindStringSubmatch(w); g != nil {
		y, m, d = n(g[1]), n(g[2]), n(g[3])
	} else if g := dateCJK.FindStringSubmatch(w); g != nil {
		y, m, d = n(g[1]), n(g[2]), n(g[3])
	} else if g := dateDMY.FindStringSubmatch(w); g != nil {
		p, q := n(g[1]), n(g[2])
		y = n(g[3])
		switch {
		case p == q:
			m, d = p, q
		case p > 12 && q <= 12:
			d, m = p, q
		case q > 12 && p <= 12:
			m, d = p, q
		default:
			return 0, 0, 0, false
		}
	} else if g := dateNameF.FindStringSubmatch(w); g != nil {
		m, d, y = monthOf(g[1]), n(g[2]), n(g[3])
	} else if g := dateNameB.FindStringSubmatch(w); g != nil {
		d, m, y = n(g[1]), monthOf(g[2]), n(g[3])
	} else {
		return 0, 0, 0, false
	}
	return y, m, d, realDate(y, m, d)
}

func dateForms(y, m, d int, w string) string {
	num := func(v int) string {
		if v < 10 {
			return "0?" + strconv.Itoa(v)
		}
		return strconv.Itoa(v)
	}
	Y, M, D := strconv.Itoa(y), num(m), num(d)
	full, abbr := monthNames[m-1], monthNames[m-1][:3]
	if m == 9 {
		abbr = "Sept|Sep"
	}
	name := `(?i:` + full + `|(?:` + abbr + `)\.?)`
	ord := `(?:st|nd|rd|th)?`
	forms := []string{
		Y + dateSep + M + dateSep + D,
		Y + `[ \t]*年[ \t]*` + M + `[ \t]*月[ \t]*` + D + `(?:[ \t]*[日号號])?`,
		Y + `[ \t]*년[ \t]*` + M + `[ \t]*월[ \t]*` + D + `(?:[ \t]*일)?`,
		Y + strconv.Itoa(100 + m)[1:] + strconv.Itoa(100 + d)[1:],
		name + `[ \t]+` + D + ord + `,?[ \t]+` + Y,
		D + ord + `(?:[ \t]+|-)` + name + `,?(?:[ \t]+|-)` + Y,
	}

	if d > 12 || d == m {
		forms = append(forms, D+dateSep+M+dateSep+Y)
		if d != m {
			forms = append(forms, M+dateSep+D+dateSep+Y)
		}
	}
	return `(?:` + strings.Join(forms, "|") + `|` + regexp.QuoteMeta(w) + `)`
}

var dateWords sync.Map

func dateWord(w string) *regexp.Regexp {
	if re, ok := dateWords.Load(w); ok {
		return re.(*regexp.Regexp)
	}
	var re *regexp.Regexp
	if y, m, d, ok := parseDateWord(w); ok {
		re = regexp.MustCompile(dateForms(y, m, d, w))
	}
	dateWords.Store(w, re)
	return re
}

func dateWhole(s string, a, b int) bool {
	isDigit := func(c byte) bool { return c >= '0' && c <= '9' }
	if a > 0 {
		if isDigit(s[a-1]) || s[a-1] == '.' && a > 1 && isDigit(s[a-2]) {
			return false
		}
		if r, _ := utf8.DecodeLastRuneInString(s[:a]); unicode.IsLetter(rune(s[a])) && unicode.IsLetter(r) && !unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Hangul) {
			return false
		}
	}
	if b < len(s) {
		if isDigit(s[b]) || s[b] == '.' && b+1 < len(s) && isDigit(s[b+1]) {
			return false
		}
	}
	return true
}

func dateSpans(s, w string) ([]span, bool) {
	re := dateWord(w)
	if re == nil {
		return nil, false
	}
	var out []span
	for _, m := range re.FindAllStringIndex(s, -1) {
		if dateWhole(s, m[0], m[1]) {
			out = append(out, span{m[0], m[1], "TERM", ByWord, 0, false})
		}
	}
	return out, true
}

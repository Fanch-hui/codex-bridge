package gateway

import (
	"strings"
)

const (
	advisorNote = "# Advisor Tool\n"
	advisorGone = "The advisor tool is no longer available; disregard the earlier advisor instructions."
)

func advisorGoneIn(text string) (string, bool) {
	i := strings.Index(text, advisorNote)
	if i < 0 {
		return text, false
	}
	end := len(text)
	if j := strings.Index(text[i:], "</system-reminder>"); j >= 0 {
		end = i + j
	}
	note := text[i:end]
	trail := note[len(strings.TrimRight(note, " \t\r\n")):]
	return text[:i] + advisorGone + trail + text[end:], true
}

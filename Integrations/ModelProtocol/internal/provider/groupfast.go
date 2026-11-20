package provider

import (
	"slices"
	"strings"

	"codexbridge/modelprotocol/internal/lazyre"
)

var (
	openAIFast = lazyre.New(`^(gpt-|o\d)`)

	claudeDated = lazyre.New(`-\d{8}$`)
)

var claudeFastModels = []string{"claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-fable-5-2"}

func ClaudeFast(model string) bool {
	return slices.Contains(claudeFastModels, claudeDated.ReplaceAllString(strings.ToLower(model), ""))
}

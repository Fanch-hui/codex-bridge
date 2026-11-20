package provider

import (
	"strings"
)

func OpenAIHost(host string) bool {
	host = strings.ToLower(host)
	return host == "openai.com" || strings.HasSuffix(host, ".openai.com")
}

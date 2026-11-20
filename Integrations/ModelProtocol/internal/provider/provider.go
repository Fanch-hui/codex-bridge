package provider

type Protocol string

const (
	Chat      Protocol = "chat"
	Responses Protocol = "responses"
	Anthropic Protocol = "anthropic"
	Gemini    Protocol = "gemini"
)

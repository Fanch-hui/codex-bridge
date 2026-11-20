package provider

import (
	"codexbridge/modelprotocol/internal/lazyre"
)

var harnessOnly = lazyre.New(`(?i)only available (?:on|with|via|in|to|for use with) agentic harness`)

const HarnessOnlyHint = "this model is only available to supported agent applications; the model without :free may be available"

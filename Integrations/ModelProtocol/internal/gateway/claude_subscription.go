package gateway

import (
	"codexbridge/modelprotocol/internal/lazyre"
)

func cacheMark1h() map[string]string {
	return map[string]string{"type": "ephemeral", "ttl": "1h"}
}

func withoutBillingHeader(system string) string {
	return billingHeader.ReplaceAllString(system, "")
}

var billingHeader = lazyre.New(`^x-anthropic-billing-header:(\s*[A-Za-z_]+=[^;\s]*;)*\s*`)

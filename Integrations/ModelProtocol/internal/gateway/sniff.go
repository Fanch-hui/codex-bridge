package gateway

func lastEvent(t string) bool {
	switch t {
	case "message_stop", "error", "response.completed", "response.incomplete", "response.failed":
		return true
	}
	return false
}

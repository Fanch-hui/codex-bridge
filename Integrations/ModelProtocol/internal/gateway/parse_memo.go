package gateway

import (
	"codexbridge/modelprotocol/internal/provider"
)

type bodyFacts struct {
	turn     int
	within   bool
	dir, git string
	compact  bool
}

type heldFacts struct {
	n     int
	proto provider.Protocol
	facts bodyFacts
}

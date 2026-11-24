package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"codexbridge/modelprotocol/internal/gateway"
)

type request struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params struct {
		RequestID      string `json:"requestId"`
		From           string `json:"from"`
		To             string `json:"to"`
		Model          string `json:"model"`
		Host           string `json:"host"`
		Body           string `json:"body"`
		Plugin         bool   `json:"plugin"`
		ReasoningScope string `json:"reasoningScope"`
		Data           string `json:"data"`
	} `json:"params"`
}

type replyError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
type reply struct {
	ID     json.RawMessage `json:"id"`
	Result any             `json:"result,omitempty"`
	Error  *replyError     `json:"error,omitempty"`
}

func dispatch(c *gateway.BridgeConverter, req request) (any, error) {
	p := req.Params
	switch req.Method {
	case "translateRequest":
		body, stream, err := c.Translate(p.RequestID, p.From, p.To, p.Model, p.Host, []byte(p.Body), p.Plugin, p.ReasoningScope)
		if err != nil {
			return nil, err
		}
		return map[string]any{"body": string(body), "stream": stream}, nil
	case "startResponse":
		if err := c.Begin(p.RequestID); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	case "responseChunk":
		data, err := base64.StdEncoding.DecodeString(p.Data)
		if err != nil {
			return nil, errors.New("invalid base64 response chunk")
		}
		out, failed, err := c.Chunk(p.RequestID, data)
		if err != nil {
			return nil, err
		}
		return map[string]any{"data": base64.StdEncoding.EncodeToString(out), "failed": failed}, nil
	case "finishResponse":
		out, err := c.Finish(p.RequestID)
		if err != nil {
			return nil, err
		}
		return map[string]any{"data": base64.StdEncoding.EncodeToString(out)}, nil
	case "cancel":
		return map[string]any{"cancelled": c.Cancel(p.RequestID)}, nil
	case "abort":
		// Frames are handled strictly in order, so the call being aborted has already finished
		// by the time this one is read. The host only needs the acknowledgement to keep this
		// shared process; per-request state is released with cancel.
		return map[string]any{}, nil
	default:
		return nil, errors.New("unknown method")
	}
}

func run(c *gateway.BridgeConverter, input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 64<<10), 64<<20)
	writer := bufio.NewWriter(output)
	defer writer.Flush()
	for scanner.Scan() {
		var req request
		res := reply{ID: json.RawMessage("null")}
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			res.Error = &replyError{Code: "invalid_request", Message: "invalid JSON request"}
		} else {
			if len(req.ID) > 0 {
				res.ID = req.ID
			}
			res.Result, err = dispatch(c, req)
			if err != nil {
				res.Error = &replyError{Code: gateway.BridgeErrorKind(err), Message: err.Error()}
			}
		}
		encoded, err := json.Marshal(res)
		if err != nil {
			return err
		}
		if _, err = writer.Write(append(encoded, '\n')); err != nil {
			return err
		}
		if err = writer.Flush(); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func main() {
	dir := flag.String("state-dir", "", "Bridge private state directory")
	flag.Parse()
	c, err := gateway.NewBridgeConverter(*dir)
	if err == nil {
		err = run(c, os.Stdin, os.Stdout)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

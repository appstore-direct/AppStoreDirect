// Command appstore-bridge speaks Apple's private App Store protocol on behalf of
// AppStoreDirect.app.
//
// It is a child process, not a service: no listener, no port, stdin and stdout only.
// It holds session state in memory for the life of one operation and persists
// nothing — the Swift app owns the macOS Keychain.
//
// The Apple protocol itself is ipatool's (MIT), vendored at a pinned commit under
// third_party/. This file only adapts it to a line-based RPC surface.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sync"
)

const protocolVersion = 1

type server struct {
	out     *bufio.Writer
	writeMu sync.Mutex
}

func main() {
	server := &server{out: bufio.NewWriter(os.Stdout)}
	defer server.out.Flush()

	// Announce the protocol version so the app can refuse a mismatched sidecar
	// rather than misparse it.
	server.write(map[string]interface{}{"event": "ready", "protocolVersion": protocolVersion})

	scanner := bufio.NewScanner(os.Stdin)
	// Requests stay small; responses are what get large.
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var incoming request
		if err := json.Unmarshal(line, &incoming); err != nil {
			server.respond(response{
				ID: "", OK: false,
				Error: &rpcError{Code: errCodeInternal, Message: "malformed request"},
			})
			continue
		}
		server.dispatch(incoming)
	}
}

func (s *server) dispatch(incoming request) {
	emit := func(name string, data interface{}) {
		s.write(event{ID: incoming.ID, Event: name, Data: data})
	}

	switch incoming.Method {
	case "ping":
		s.respond(response{ID: incoming.ID, OK: true, Result: map[string]int{"protocolVersion": protocolVersion}})

	case "login":
		var params loginParams
		if failure := decodeParams(incoming.Params, &params); failure != nil {
			s.respond(response{ID: incoming.ID, OK: false, Error: failure})
			return
		}
		result, failure := handleLogin(params)
		s.finish(incoming.ID, result, failure)

	case "resume":
		var params resumeParams
		if failure := decodeParams(incoming.Params, &params); failure != nil {
			s.respond(response{ID: incoming.ID, OK: false, Error: failure})
			return
		}
		result, failure := handleResume(params)
		s.finish(incoming.ID, result, failure)

	case "acquire":
		var params acquireParams
		if failure := decodeParams(incoming.Params, &params); failure != nil {
			s.respond(response{ID: incoming.ID, OK: false, Error: failure})
			return
		}
		result, failure := handleAcquire(incoming.ID, params, emit)
		s.finish(incoming.ID, result, failure)

	case "ownership":
		var params ownershipParams
		if failure := decodeParams(incoming.Params, &params); failure != nil {
			s.respond(response{ID: incoming.ID, OK: false, Error: failure})
			return
		}
		result, failure := handleOwnership(params)
		s.finish(incoming.ID, result, failure)

	case "purchase":
		var params purchaseParams
		if failure := decodeParams(incoming.Params, &params); failure != nil {
			s.respond(response{ID: incoming.ID, OK: false, Error: failure})
			return
		}
		result, failure := handlePurchase(params)
		s.finish(incoming.ID, result, failure)

	case "authorize":
		var params authorizeParams
		if failure := decodeParams(incoming.Params, &params); failure != nil {
			s.respond(response{ID: incoming.ID, OK: false, Error: failure})
			return
		}
		result, failure := handleAuthorize(params)
		s.finish(incoming.ID, result, failure)

	case "versions":
		var params versionsParams
		if failure := decodeParams(incoming.Params, &params); failure != nil {
			s.respond(response{ID: incoming.ID, OK: false, Error: failure})
			return
		}
		result, failure := handleVersions(params)
		s.finish(incoming.ID, result, failure)

	default:
		s.respond(response{
			ID: incoming.ID, OK: false,
			Error: &rpcError{Code: errCodeInternal, Message: fmt.Sprintf("unknown method %q", incoming.Method)},
		})
	}
}

func (s *server) finish(id string, result interface{}, failure *rpcError) {
	if failure != nil {
		s.respond(response{ID: id, OK: false, Error: failure})
		return
	}
	s.respond(response{ID: id, OK: true, Result: result})
}

func (s *server) respond(value response) {
	s.write(value)
}

func (s *server) write(value interface{}) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.out.Write(encoded)
	s.out.WriteByte('\n')
	// Flushed per message: the app blocks on progress events.
	s.out.Flush()
}

func decodeParams(raw rawJSON, target interface{}) *rpcError {
	if len(raw) == 0 {
		return &rpcError{Code: errCodeInternal, Message: "missing params"}
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return &rpcError{Code: errCodeInternal, Message: "malformed params"}
	}
	return nil
}

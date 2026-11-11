package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

// The vsock ports, fixed for the life of every guest: a stub installed at create must still find
// the host after any number of hobo upgrades.
const (
	// The host listens here for the stub's fetch (frozen: see stub.go).
	fetchPort = 1100
	// The agent listens here for the host's requests.
	agentPort = 1101
	// VMADDR_CID_HOST: the only peer the agent accepts.
	hostCID = 2
)

// protocolVersion is bumped on any incompatible change to a request or a frame. The agent always
// comes from the host it serves (the stub fetches it on every boot), so this only guards against
// a guest that kept an agent running across a host upgrade, as a suspended VM does.
const protocolVersion = 1

// request is the one JSON line that opens every connection from the host.
type request struct {
	Version int    `json:"version"`
	Op      string `json:"op"` // ping, exec, put, get, clipboard
	// exec: a command line for User's login shell, as sshd would run it.
	Command string `json:"command,omitempty"`
	// exec on Windows: run it in the console's desktop session (`exec --gui`). Elsewhere the
	// host's command line gets there itself, and this is false.
	Desktop bool `json:"desktop,omitempty"`
	// exec: a tool (tool.go) to fetch before the command runs, which the command can then run.
	Tool string `json:"tool,omitempty"`
	// exec, put, get, clipboard: who runs it, and whose files the copy reads or writes.
	User string `json:"user,omitempty"`
	// put: where the copy goes; single says the tar holds one top-level entry.
	Destination string `json:"destination,omitempty"`
	Single      bool   `json:"single,omitempty"`
	// get: what is copied.
	Sources   []string `json:"sources,omitempty"`
	Recursive bool     `json:"recursive,omitempty"`
}

// Frames carry everything after the request, in both directions: a type byte, a big-endian
// uint32 length, then that many bytes. Output never needs encoding, and a tar stream can't be
// confused with a message.
const (
	frameStdout = '1'
	frameStderr = '2'
	// A chunk of a tar stream: put's from the host, get's to it. An empty one ends the stream.
	frameData = 'd'
	// A chunk of clipboard text (UTF-8, LF line endings), either way; an empty one ends the text.
	frameText = 't'
	// Ends a request: its exit status as a big-endian int32.
	frameExit = 'x'
	// Ends a request that couldn't run, with the reason as text.
	frameError = 'r'
)

const maxFrame = 1 << 20

// frameWriter serialises frames from several goroutines (a command's stdout and stderr).
type frameWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (f *frameWriter) write(kind byte, payload []byte) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for {
		chunk := payload
		if len(chunk) > maxFrame {
			chunk = chunk[:maxFrame]
		}
		var header [5]byte
		header[0] = kind
		binary.BigEndian.PutUint32(header[1:], uint32(len(chunk)))
		if _, err := f.w.Write(header[:]); err != nil {
			return err
		}
		if _, err := f.w.Write(chunk); err != nil {
			return err
		}
		payload = payload[len(chunk):]
		if len(payload) == 0 {
			return nil
		}
	}
}

func (f *frameWriter) exit(status int32) error {
	var payload [4]byte
	binary.BigEndian.PutUint32(payload[:], uint32(status))
	return f.write(frameExit, payload[:])
}

func (f *frameWriter) fail(format string, args ...any) error {
	return f.write(frameError, []byte(fmt.Sprintf(format, args...)))
}

// streamWriter turns writes into frames of one kind, for io.Copy.
type streamWriter struct {
	frames *frameWriter
	kind   byte
}

func (s streamWriter) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if err := s.frames.write(s.kind, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func readFrame(r io.Reader) (byte, []byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(header[1:])
	if n > maxFrame {
		return 0, nil, fmt.Errorf("frame of %d bytes is over the %d-byte limit", n, maxFrame)
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	return header[0], payload, nil
}

// dataReader reads the payloads of data frames until the empty one that ends them.
type dataReader struct {
	r       io.Reader
	pending []byte
	done    bool
}

func (d *dataReader) Read(p []byte) (int, error) {
	for len(d.pending) == 0 {
		if d.done {
			return 0, io.EOF
		}
		kind, payload, err := readFrame(d.r)
		if err != nil {
			return 0, err
		}
		if kind != frameData {
			return 0, fmt.Errorf("expected a data frame, got %q", kind)
		}
		if len(payload) == 0 {
			d.done = true
		}
		d.pending = payload
	}
	n := copy(p, d.pending)
	d.pending = d.pending[n:]
	return n, nil
}

var errLineTooLong = errors.New("request line is too long")

// readRequest reads the opening line without reading past it, so what follows stays unread.
func readRequest(r *bufio.Reader) (request, error) {
	var line []byte
	for {
		chunk, isPrefix, err := r.ReadLine()
		if err != nil {
			return request{}, err
		}
		line = append(line, chunk...)
		if len(line) > maxFrame {
			return request{}, errLineTooLong
		}
		if !isPrefix {
			break
		}
	}
	var req request
	if err := json.Unmarshal(line, &req); err != nil {
		return request{}, fmt.Errorf("bad request: %v", err)
	}
	return req, nil
}

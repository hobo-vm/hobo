package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"time"
)

// serve answers the host's requests, one per connection, until the guest shuts down.
func serve() {
	listener, err := vsockListen(agentPort)
	if err != nil {
		fmt.Fprintf(os.Stderr, "hobo-agent: %v\n", err)
		os.Exit(1)
	}
	for {
		conn, cid, err := vsockAccept(listener)
		if err != nil {
			fmt.Fprintf(os.Stderr, "hobo-agent: %v\n", err)
			os.Exit(1)
		}
		// Only the host may ask: the agent runs as root, and a guest process connecting over
		// vsock loopback mustn't get that for nothing.
		if cid != hostCID {
			conn.Close()
			continue
		}
		go handle(conn)
	}
}

func handle(conn io.ReadWriteCloser) {
	defer conn.Close()
	reader := bufio.NewReader(conn)
	frames := &frameWriter{w: conn}
	req, err := readRequest(reader)
	if err != nil {
		_ = frames.fail("%v", err)
		return
	}
	if req.Version != protocolVersion {
		_ = frames.fail("this hobo-agent speaks protocol %d, not %d (restart the VM to get the host's agent)", protocolVersion, req.Version)
		return
	}
	switch req.Op {
	case "ping":
		_ = frames.exit(0)
	case "exec":
		runExec(req, reader, frames)
	case "put":
		runPut(req, reader, frames)
	case "get":
		runGet(req, reader, frames)
	case "clipboard":
		runClipboardRequest(req, reader, frames)
	default:
		_ = frames.fail("unknown request %q", req.Op)
	}
}

// process is a command a request started, through the platform's start.
type process interface {
	// Stdin is the command's input, if its commandSpec asked for one.
	Stdin() io.WriteCloser
	// Wait waits for the command to exit and its output to be passed on, and gives its exit
	// status as a shell would report it.
	Wait() (int32, error)
	// Terminate ends the command and everything it started.
	Terminate()
}

// commandSpec is what start runs: a command line in the user's shell, or this binary's own
// put, get or clipboard.
type commandSpec struct {
	user string
	// A command line for the user's login shell, or else this binary's arguments.
	line string
	self []string
	// In the console's desktop session: on Windows for any command, and on macOS for this
	// binary's own (a command line gets there itself, `VMBundle.agentCommand`).
	desktop bool
	stdin   bool
	stdout  io.Writer
	stderr  io.Writer
}

// As GUISession has it: how long a start in the desktop session waits for it, and what the
// request exits with then.
const (
	desktopWaitSeconds       = 60
	desktopUnavailableStatus = 125
)

// exitEarly is a start that ends the request with a status of its own, having said why.
type exitEarly struct {
	status  int32
	message string
}

func (e exitEarly) Error() string { return e.message }

// runExec runs the command as the request's user and streams its output. The host closing the
// connection cancels it: nothing else is ever sent, so any read returning means the host is gone.
func runExec(req request, conn io.Reader, frames *frameWriter) {
	if req.Tool != "" {
		if err := ensureTool(req.Tool, req.User); err != nil {
			_ = frames.fail("%v", err)
			return
		}
	}
	proc, err := start(commandSpec{
		user: req.User, line: req.Command, desktop: req.Desktop,
		stdout: streamWriter{frames, frameStdout}, stderr: streamWriter{frames, frameStderr},
	})
	if !started(err, frames) {
		return
	}
	run(proc, conn, frames, nil, nil)
}

// runPut extracts the host's tar stream as the request's user, by running this binary's `put`
// as them: the agent itself stays root.
func runPut(req request, conn io.Reader, frames *frameWriter) {
	single := "0"
	if req.Single {
		single = "1"
	}
	proc, err := start(commandSpec{
		user: req.User, self: []string{"put", req.Destination, single}, stdin: true,
		stdout: streamWriter{frames, frameStderr}, stderr: streamWriter{frames, frameStderr},
	})
	if !started(err, frames) {
		return
	}
	// The tar stream comes first; once it has ended, a read returning means the host is gone.
	data := &dataReader{r: conn}
	run(proc, conn, frames, func() {
		stdin := proc.Stdin()
		_, _ = io.Copy(stdin, data)
		stdin.Close()
		// The rest, if `put` stopped reading: the host sends all of it before it reads an answer.
		_, _ = io.Copy(io.Discard, data)
	}, nil)
}

// runGet sends a tar stream of the request's sources, read as its user.
func runGet(req request, conn io.Reader, frames *frameWriter) {
	recursive := "0"
	if req.Recursive {
		recursive = "1"
	}
	proc, err := start(commandSpec{
		user: req.User, self: append([]string{"get", recursive}, req.Sources...),
		stdout: streamWriter{frames, frameData}, stderr: streamWriter{frames, frameStderr},
	})
	if !started(err, frames) {
		return
	}
	run(proc, conn, frames, nil, func() {
		_ = frames.write(frameData, nil) // Ends the stream, now that Wait has passed all of it on.
	})
}

// How long the clipboard helper has to exit once the host hangs up, before it is terminated.
const clipboardHelperGrace = 5 * time.Second

// runClipboardRequest runs `hobo-agent clipboard` as the request's user in the desktop session, and
// relays text frames between it and the host until either ends: the host hanging up (hiding its
// window) closes the helper's input, which ends it. The helper's frames are read whole and
// passed on, so its stderr's frames can't land inside one.
func runClipboardRequest(req request, conn io.Reader, frames *frameWriter) {
	fromHelper, helperOut := io.Pipe()
	proc, err := start(commandSpec{
		user: req.User, self: []string{"clipboard"}, desktop: true, stdin: true,
		stdout: helperOut, stderr: streamWriter{frames, frameStderr},
	})
	if !started(err, frames) {
		return
	}
	relayed := make(chan struct{})
	go func() {
		defer close(relayed)
		for {
			kind, payload, err := readFrame(fromHelper)
			if err != nil {
				_, _ = io.Copy(io.Discard, fromHelper)
				return
			}
			_ = frames.write(kind, payload)
		}
	}()
	exited := make(chan struct{})
	go func() {
		stdin := proc.Stdin()
		_, _ = io.Copy(stdin, conn)
		stdin.Close()
		select {
		case <-exited:
		case <-time.After(clipboardHelperGrace):
			proc.Terminate()
		}
	}()
	status, err := proc.Wait()
	close(exited)
	helperOut.Close()
	<-relayed
	if err != nil {
		_ = frames.fail("%v", err)
		return
	}
	_ = frames.exit(status)
}

// started reports a start that failed, and says whether the request goes on.
func started(err error, frames *frameWriter) bool {
	if early, ok := err.(exitEarly); ok {
		_ = frames.write(frameStderr, []byte(early.message+"\n"))
		_ = frames.exit(early.status)
		return false
	}
	if err != nil {
		_ = frames.fail("%v", err)
		return false
	}
	return true
}

// run does feed (copying the command's input) if there is one, then waits for the command while
// watching the connection: the host hanging up terminates it. Once it has exited, its output is
// sent and its input all read, finish runs if there is one, then the exit frame ends the request.
// Answering before the host's stream has all been read would cut it off: tar stops reading at
// its end-of-archive blocks, short of the stream's end.
func run(proc process, conn io.Reader, frames *frameWriter, feed func(), finish func()) {
	exited := make(chan struct{})
	fed := make(chan struct{})
	go func() {
		if feed != nil {
			feed()
		}
		close(fed)
		var buffer [1]byte
		_, _ = conn.Read(buffer[:])
		select {
		case <-exited:
		default:
			proc.Terminate()
		}
	}()
	status, err := proc.Wait()
	close(exited)
	<-fed
	if err != nil {
		_ = frames.fail("%v", err)
		return
	}
	if finish != nil {
		finish()
	}
	_ = frames.exit(status)
}

func selfPath() string {
	path, err := os.Executable()
	if err != nil {
		return os.Args[0]
	}
	return path
}

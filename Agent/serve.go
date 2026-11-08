package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
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

func handle(conn *os.File) {
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
	default:
		_ = frames.fail("unknown request %q", req.Op)
	}
}

// runExec runs the command as the request's user and streams its output. The host closing the
// connection cancels it: nothing else is ever sent, so any read returning means the host is gone.
func runExec(req request, conn io.Reader, frames *frameWriter) {
	who, err := lookupAccount(req.User)
	if err != nil {
		_ = frames.fail("%v", err)
		return
	}
	cmd := who.command(req.Command)
	cmd.Stdout = streamWriter{frames, frameStdout}
	cmd.Stderr = streamWriter{frames, frameStderr}
	run(cmd, conn, frames, nil, nil)
}

// runPut extracts the host's tar stream as the request's user, by running this binary's `put`
// as them: the agent itself stays root.
func runPut(req request, conn io.Reader, frames *frameWriter) {
	who, err := lookupAccount(req.User)
	if err != nil {
		_ = frames.fail("%v", err)
		return
	}
	single := "0"
	if req.Single {
		single = "1"
	}
	cmd := exec.Command(selfPath(), "put", req.Destination, single)
	who.configure(cmd)
	cmd.Stdout = streamWriter{frames, frameStderr}
	cmd.Stderr = streamWriter{frames, frameStderr}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		_ = frames.fail("%v", err)
		return
	}
	// The tar stream comes first; once it has ended, a read returning means the host is gone.
	data := &dataReader{r: conn}
	run(cmd, conn, frames, func() {
		_, _ = io.Copy(stdin, data)
		stdin.Close()
		// The rest, if `put` stopped reading: the host sends all of it before it reads an answer.
		_, _ = io.Copy(io.Discard, data)
	}, nil)
}

// runGet sends a tar stream of the request's sources, read as its user.
func runGet(req request, conn io.Reader, frames *frameWriter) {
	who, err := lookupAccount(req.User)
	if err != nil {
		_ = frames.fail("%v", err)
		return
	}
	recursive := "0"
	if req.Recursive {
		recursive = "1"
	}
	cmd := exec.Command(selfPath(), append([]string{"get", recursive}, req.Sources...)...)
	who.configure(cmd)
	cmd.Stdout = streamWriter{frames, frameData}
	cmd.Stderr = streamWriter{frames, frameStderr}
	run(cmd, conn, frames, nil, func() {
		_ = frames.write(frameData, nil) // Ends the stream, now that cmd.Wait has copied all of it.
	})
}

// run starts cmd, does feed (copying its input) if there is one, then waits for it while watching
// the connection: the host hanging up kills the command's process group. Once it has exited and
// its output is sent, finish runs if there is one, then the exit frame ends the request.
func run(cmd *exec.Cmd, conn io.Reader, frames *frameWriter, feed func(), finish func()) {
	if err := cmd.Start(); err != nil {
		_ = frames.fail("%v", err)
		return
	}
	exited := make(chan struct{})
	go func() {
		if feed != nil {
			feed()
		}
		var buffer [1]byte
		_, _ = conn.Read(buffer[:])
		select {
		case <-exited:
		default:
			terminate(cmd, exited)
		}
	}()
	err := cmd.Wait()
	close(exited)
	status, ok := exitStatus(err)
	if !ok {
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

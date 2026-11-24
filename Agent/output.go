package main

import (
	"io"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// How long a command's output can be quiet, once the command has exited, before the request is
// answered without waiting for its end.
var outputGrace = time.Second

// outputRelay passes a command's output on from the pipes it writes to. Their end can't be waited
// for: a process the command left running (`server &`, an app) may hold them open for good. So
// once the command has exited, finish waits only until nothing has come for outputGrace, and what
// is written after that is read and dropped, which keeps the writer from blocking or being
// killed by a closed pipe.
type outputRelay struct {
	streams []*outputStream
	copies  sync.WaitGroup
}

type outputStream struct {
	gate
	ended atomic.Bool
	// When the read it is waiting in began, in Unix nanoseconds; 0 while it passes output on. A
	// slow host holds it at 0, so the grace never cuts off output that has already been written.
	waitingSince atomic.Int64
}

// add passes on what read gives to output, and closes read at its end.
func (r *outputRelay) add(read *os.File, output io.Writer) {
	stream := &outputStream{gate: gate{w: output}}
	r.streams = append(r.streams, stream)
	r.copies.Add(1)
	go func() {
		defer r.copies.Done()
		defer read.Close()
		defer stream.ended.Store(true)
		buffer := make([]byte, 32*1024)
		for {
			stream.waitingSince.Store(time.Now().UnixNano())
			n, err := read.Read(buffer)
			stream.waitingSince.Store(0)
			if n > 0 {
				_, _ = stream.Write(buffer[:n])
			}
			if err != nil {
				return
			}
		}
	}()
}

// finish is for once the command has exited: it returns when all its output has been passed on,
// or none has come for outputGrace.
func (r *outputRelay) finish() {
	exited := time.Now().UnixNano()
	ended := make(chan struct{})
	go func() {
		r.copies.Wait()
		close(ended)
	}()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for done := false; !done; {
		select {
		case <-ended:
			done = true
		case <-tick.C:
			done = r.quiet(exited)
		}
	}
	for _, stream := range r.streams {
		stream.close()
	}
}

// quiet is whether every stream still open has waited outputGrace for more. The wait counts from
// when the command exited, at the earliest: a read that began long before may not have woken yet
// for what the command wrote last.
func (r *outputRelay) quiet(exited int64) bool {
	now := time.Now().UnixNano()
	for _, stream := range r.streams {
		if stream.ended.Load() {
			continue
		}
		since := stream.waitingSince.Load()
		passingOutputOn := since == 0
		if passingOutputOn || now-max(since, exited) < int64(outputGrace) {
			return false
		}
	}
	return true
}

// gate passes writes on until it is closed, and then drops them.
type gate struct {
	mutex  sync.Mutex
	w      io.Writer
	closed bool
}

func (g *gate) Write(b []byte) (int, error) {
	g.mutex.Lock()
	defer g.mutex.Unlock()
	if g.closed {
		return len(b), nil
	}
	return g.w.Write(b)
}

func (g *gate) close() {
	g.mutex.Lock()
	g.closed = true
	g.mutex.Unlock()
}

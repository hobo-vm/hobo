package main

import (
	"testing"
	"time"
)

// The grace counts from the command's exit: a read that has waited since long before isn't quiet
// until the grace has passed since then, since it may not have woken yet for the command's last
// output. A stream passing output on is never quiet, and one that has ended always is.
func TestOutputIsQuietOnlyOnceTheGraceHasPassedSinceTheCommandExited(t *testing.T) {
	grace := outputGrace
	outputGrace = 50 * time.Millisecond
	defer func() { outputGrace = grace }()
	stream := &outputStream{}
	relay := &outputRelay{streams: []*outputStream{stream}}
	began := relayClock()
	stream.waitingSince.Store(began)
	time.Sleep(2 * outputGrace)
	if relay.quiet(relayClock()) {
		t.Fatal("quiet as the command exited, with a read that had waited longer than the grace")
	}
	if !relay.quiet(began) {
		t.Fatal("not quiet, the grace after the command exited")
	}
	stream.waitingSince.Store(0)
	if relay.quiet(began) {
		t.Fatal("quiet while passing output on")
	}
	stream.ended.Store(true)
	if !relay.quiet(relayClock()) {
		t.Fatal("not quiet with its only stream ended")
	}
}

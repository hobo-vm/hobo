package main

import (
	"bytes"
	"io"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeClipboard stands in for a guest's clipboard, recording what the helper set it to.
type fakeClipboard struct {
	mu     sync.Mutex
	text   string
	writes []string
}

func (f *fakeClipboard) changed() bool { return true }

func (f *fakeClipboard) read() (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.text, nil
}

func (f *fakeClipboard) write(text string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.text = text
	f.writes = append(f.writes, text)
	return nil
}

// copy is the guest's user copying text.
func (f *fakeClipboard) copy(text string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.text = text
}

func (f *fakeClipboard) written() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.writes...)
}

// syncBuffer is a bytes.Buffer the helper writes and the test reads at once.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

// texts decodes every text the helper has sent so far.
func (s *syncBuffer) texts(t *testing.T) []string {
	s.mu.Lock()
	data := append([]byte(nil), s.buf.Bytes()...)
	s.mu.Unlock()
	var got []string
	if err := readClipboardTexts(bytes.NewReader(data), func(text string) { got = append(got, text) }); err != nil {
		t.Fatal(err)
	}
	return got
}

func eventually(t *testing.T, what string, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !check() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// hostSends frames text as the host does.
func hostSends(t *testing.T, w io.Writer, text string) {
	t.Helper()
	if err := writeClipboardText(&frameWriter{w: w}, text); err != nil {
		t.Fatal(err)
	}
}

func TestClipboardSharesNewCopiesButNotEchoesOrWhatWasThere(t *testing.T) {
	board := &fakeClipboard{text: "there before"}
	hostIn, toHelper := io.Pipe()
	var out syncBuffer
	done := make(chan error, 1)
	go func() { done <- runClipboard(board, hostIn, &out, time.Millisecond) }()

	// The host's text is set, and isn't sent back.
	hostSends(t, toHelper, "from the host")
	eventually(t, "the host's text to be set", func() bool { return len(board.written()) == 1 })
	if got := board.written(); got[0] != "from the host" {
		t.Fatalf("set %q", got)
	}
	// The guest's copy is sent, once.
	board.copy("from the guest")
	eventually(t, "the guest's copy to be sent", func() bool { return len(out.texts(t)) == 1 })
	time.Sleep(20 * time.Millisecond)
	if got := out.texts(t); len(got) != 1 || got[0] != "from the guest" {
		t.Fatalf("sent %q", got)
	}
	// An emptied clipboard isn't shared.
	board.copy("")
	time.Sleep(20 * time.Millisecond)
	if got := out.texts(t); len(got) != 1 {
		t.Fatalf("sent %q", got)
	}

	toHelper.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the helper didn't end with its input")
	}
}

func TestClipboardTextsSpanFramesAndOversizedOnesAreDropped(t *testing.T) {
	var stream bytes.Buffer
	frames := &frameWriter{w: &stream}
	big := strings.Repeat("x", maxFrame+5)
	if err := writeClipboardText(frames, big); err != nil {
		t.Fatal(err)
	}
	if err := writeClipboardText(frames, strings.Repeat("y", maxClipboardText+1)); err != nil {
		t.Fatal(err)
	}
	if err := writeClipboardText(frames, "after"); err != nil {
		t.Fatal(err)
	}
	var got []string
	if err := readClipboardTexts(&stream, func(text string) { got = append(got, text) }); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != big || got[1] != "after" {
		t.Fatalf("got %d texts", len(got))
	}
}

func TestClipboardRefusesOtherFrames(t *testing.T) {
	var stream bytes.Buffer
	_ = (&frameWriter{w: &stream}).write(frameStdout, []byte("x"))
	if err := readClipboardTexts(&stream, func(string) {}); err == nil {
		t.Fatal("a stdout frame read as clipboard text")
	}
}

func TestWindowsLineEndings(t *testing.T) {
	if got := lfToCRLF("a\nb\r\nc"); got != "a\r\nb\r\nc" {
		t.Errorf("lfToCRLF = %q", got)
	}
	if got := crlfToLF("a\r\nb\nc"); got != "a\nb\nc" {
		t.Errorf("crlfToLF = %q", got)
	}
}

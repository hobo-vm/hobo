package main

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// The shared clipboard (decision 17): while the host's window onto the guest shows, the host
// holds a `clipboard` request open, and the agent runs `hobo-agent clipboard` in the desktop
// session, where the guest's clipboard is. Text goes both ways as text frames, chunked like any
// frame and ended by an empty one; a later kind (images) would be a frame type of its own.

// The largest text either side shares; anything bigger is skipped, and said so.
const maxClipboardText = 16 << 20

// How often the helper looks for a change in the guest's clipboard.
const clipboardPoll = 500 * time.Millisecond

// guestClipboard is the desktop session's clipboard. It reads the platform's text as it is, and
// writes text in wire form (`wireText`), converting it to the platform's line endings.
type guestClipboard interface {
	// changed is a cheap check whether the clipboard may have changed since it was last asked;
	// a platform with no such check always says it may have.
	changed() bool
	// read gives the clipboard's text, or "" if it holds none.
	read() (string, error)
	write(text string) error
}

// runClipboard is `hobo-agent clipboard`: it sets the guest's clipboard to each text the host sends
// on in, and sends each new text the guest's clipboard takes on out, until in ends (the host has
// gone). What the clipboard holds when it starts isn't sent: it isn't new, and would overwrite
// whatever the host copied since. A text is never sent back to where it came from, so the two
// sides can't echo one another. Every text, whether from the host or read from the guest, is put in
// wire form here, before it is written, compared or sent: that one place is what makes a text the
// host sends compare equal to the guest's read-back of it, whatever the host did to it first.
func runClipboard(board guestClipboard, in io.Reader, out io.Writer, poll time.Duration) error {
	frames := &frameWriter{w: out}
	last, err := board.read()
	if err != nil {
		fmt.Fprintf(os.Stderr, "reading the clipboard: %v\n", err)
	}
	last = wireText(last)
	board.changed()
	incoming := make(chan string)
	ended := make(chan error, 1)
	go func() {
		ended <- readClipboardTexts(in, func(text string) { incoming <- text })
	}()
	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	for {
		select {
		case text := <-incoming:
			text = wireText(text)
			if err := board.write(text); err != nil {
				fmt.Fprintf(os.Stderr, "setting the clipboard: %v\n", err)
				continue
			}
			last = text
		case err := <-ended:
			return err
		case <-ticker.C:
			if !board.changed() {
				continue
			}
			text, err := board.read()
			if err != nil {
				fmt.Fprintf(os.Stderr, "reading the clipboard: %v\n", err)
				continue
			}
			text = wireText(text)
			if text == last || text == "" {
				continue
			}
			last = text
			if len(text) > maxClipboardText {
				fmt.Fprintf(os.Stderr, "not sharing the clipboard's %d bytes of text: over the %d-byte limit\n", len(text), maxClipboardText)
				continue
			}
			if err := writeClipboardText(frames, text); err != nil {
				return err
			}
		}
	}
}

// writeClipboardText sends one text: its frames, then the empty one that ends it.
func writeClipboardText(frames *frameWriter, text string) error {
	if err := frames.write(frameText, []byte(text)); err != nil {
		return err
	}
	return frames.write(frameText, nil)
}

// readClipboardTexts passes each text in carries to set, until in ends cleanly (nil) or breaks.
// A text over the limit is dropped, and said so.
func readClipboardTexts(in io.Reader, set func(string)) error {
	var text []byte
	over := false
	for {
		kind, payload, err := readFrame(in)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if kind != frameText {
			return fmt.Errorf("expected a text frame, got %q", kind)
		}
		if len(payload) > 0 {
			if len(text)+len(payload) > maxClipboardText {
				over = true
				text = nil
			}
			if !over {
				text = append(text, payload...)
			}
			continue
		}
		if over {
			fmt.Fprintf(os.Stderr, "not setting the clipboard: the host's text is over the %d-byte limit\n", maxClipboardText)
		} else if len(text) > 0 {
			set(string(text))
		}
		text, over = nil, false
	}
}

// wireText is a text's wire form, as frameText carries it: every line ends in LF alone. A line
// ending of CRs then LF (CRLF, or the CRCRLF some converters leave) becomes LF; a CR anywhere else
// stays. It is idempotent, and lfToCRLF of a wire text comes back unchanged through it, so a text
// survives a Windows guest's clipboard as it went in. ClipboardSync.wireText is the host's copy.
func wireText(text string) string {
	if !strings.Contains(text, "\r\n") {
		return text
	}
	out := make([]byte, 0, len(text))
	for i := 0; i < len(text); i++ {
		if text[i] == '\n' {
			for len(out) > 0 && out[len(out)-1] == '\r' {
				out = out[:len(out)-1]
			}
		}
		out = append(out, text[i])
	}
	return string(out)
}

// lfToCRLF gives a wire text Windows' line endings.
func lfToCRLF(text string) string { return strings.ReplaceAll(text, "\n", "\r\n") }

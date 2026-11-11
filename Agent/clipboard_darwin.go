package main

import (
	"os/exec"
	"strings"
)

// pasteboard is the macOS guest's general pasteboard, through pbpaste and pbcopy: the agent builds
// without cgo, so AppKit's NSPasteboard is out of reach. They find the pasteboard server in the
// Aqua session the helper was started in, and take their encoding from LANG (UTF-8, from the
// login environment). There is no cheap change check (changeCount is AppKit's), so every poll
// reads it.
type pasteboard struct{}

func newGuestClipboard() (guestClipboard, error) { return pasteboard{}, nil }

func (pasteboard) changed() bool { return true }

func (pasteboard) read() (string, error) {
	out, err := exec.Command("/usr/bin/pbpaste").Output()
	return string(out), err
}

func (pasteboard) write(text string) error {
	cmd := exec.Command("/usr/bin/pbcopy")
	cmd.Stdin = strings.NewReader(text)
	return cmd.Run()
}

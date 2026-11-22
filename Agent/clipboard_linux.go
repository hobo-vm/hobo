package main

import "errors"

// Linux guests don't share the clipboard yet: reading GNOME's on Wayland from outside a focused
// app is the open question (issue #14), and the host never asks.
func newGuestClipboard() (guestClipboard, error) {
	return nil, errors.New("the shared clipboard is for macOS and Windows guests")
}

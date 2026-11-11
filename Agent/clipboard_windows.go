package main

import (
	"errors"
	"fmt"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var (
	user32                         = syscall.NewLazyDLL("user32.dll")
	procOpenClipboard              = user32.NewProc("OpenClipboard")
	procCloseClipboard             = user32.NewProc("CloseClipboard")
	procEmptyClipboard             = user32.NewProc("EmptyClipboard")
	procGetClipboardData           = user32.NewProc("GetClipboardData")
	procSetClipboardData           = user32.NewProc("SetClipboardData")
	procIsClipboardFormatAvailable = user32.NewProc("IsClipboardFormatAvailable")
	procGetClipboardSequenceNumber = user32.NewProc("GetClipboardSequenceNumber")
	procGlobalAlloc                = kernel32.NewProc("GlobalAlloc")
	procGlobalFree                 = kernel32.NewProc("GlobalFree")
	procGlobalLock                 = kernel32.NewProc("GlobalLock")
	procGlobalUnlock               = kernel32.NewProc("GlobalUnlock")
	procGlobalSize                 = kernel32.NewProc("GlobalSize")
	procRtlMoveMemory              = kernel32.NewProc("RtlMoveMemory")
)

const (
	cfUnicodeText = 13
	gmemMoveable  = 0x0002
)

// windowsClipboard is the desktop session's clipboard, as CF_UNICODETEXT through user32. Its
// sequence number changes with every change, so a poll that finds it the same reads nothing,
// and never holds the clipboard open while another app wants it.
type windowsClipboard struct {
	sequence uintptr
}

func newGuestClipboard() (guestClipboard, error) { return &windowsClipboard{}, nil }

func (c *windowsClipboard) changed() bool {
	sequence, _, _ := procGetClipboardSequenceNumber.Call()
	if sequence == c.sequence {
		return false
	}
	c.sequence = sequence
	return true
}

// openClipboard waits briefly for an app that has the clipboard open to close it.
func openClipboard() error {
	for range 20 {
		if r, _, _ := procOpenClipboard.Call(0); r != 0 {
			return nil
		}
		time.Sleep(25 * time.Millisecond)
	}
	return errors.New("another app has the clipboard open")
}

func (c *windowsClipboard) read() (string, error) {
	if err := openClipboard(); err != nil {
		return "", err
	}
	defer procCloseClipboard.Call()
	if r, _, _ := procIsClipboardFormatAvailable.Call(cfUnicodeText); r == 0 {
		return "", nil
	}
	handle, _, err := procGetClipboardData.Call(cfUnicodeText)
	if handle == 0 {
		return "", fmt.Errorf("getting its text: %w", err)
	}
	size, _, _ := procGlobalSize.Call(handle)
	pointer, _, err := procGlobalLock.Call(handle)
	if pointer == 0 {
		return "", fmt.Errorf("locking its text: %w", err)
	}
	defer procGlobalUnlock.Call(handle)
	units := make([]uint16, size/2)
	if len(units) > 0 {
		// Copied rather than viewed in place: the memory is the clipboard's, not Go's.
		procRtlMoveMemory.Call(uintptr(unsafe.Pointer(&units[0])), pointer, uintptr(len(units)*2))
	}
	for i, unit := range units {
		if unit == 0 {
			units = units[:i]
			break
		}
	}
	return crlfToLF(string(utf16.Decode(units))), nil
}

func (c *windowsClipboard) write(text string) error {
	units := append(utf16.Encode([]rune(lfToCRLF(text))), 0)
	if err := openClipboard(); err != nil {
		return err
	}
	defer procCloseClipboard.Call()
	if r, _, err := procEmptyClipboard.Call(); r == 0 {
		return fmt.Errorf("emptying it: %w", err)
	}
	handle, _, err := procGlobalAlloc.Call(gmemMoveable, uintptr(len(units)*2))
	if handle == 0 {
		return fmt.Errorf("allocating its text: %w", err)
	}
	pointer, _, err := procGlobalLock.Call(handle)
	if pointer == 0 {
		procGlobalFree.Call(handle)
		return fmt.Errorf("locking its text: %w", err)
	}
	procRtlMoveMemory.Call(pointer, uintptr(unsafe.Pointer(&units[0])), uintptr(len(units)*2))
	procGlobalUnlock.Call(handle)
	// The clipboard owns the memory once this succeeds.
	if r, _, err := procSetClipboardData.Call(cfUnicodeText, handle); r == 0 {
		procGlobalFree.Call(handle)
		return fmt.Errorf("setting its text: %w", err)
	}
	return nil
}

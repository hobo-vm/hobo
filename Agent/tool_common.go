package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"sync"
)

// Tools are executables the host serves for the agent to run, fetched on first use each boot
// like the agent itself, and again when the host's digest of the tool (`toolDigest`) differs
// from the one fetched, as after hobo is updated under a running VM, so they match the hobo
// asking for them. An exec request naming
// one (`tool`) has it in place before its command runs. Only `ui` exists: `hobo ui`'s driver in a
// macOS guest (designs/hobo-ui.md), its backend in a Linux or Windows one
// (designs/hobo-ui-linux-windows.md).
var tools = map[string]bool{"ui": true}

var toolLock sync.Mutex

// hasTool reports whether the file at path is there and, given a digest, is the tool it names.
func hasTool(path, digest string) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	if digest == "" {
		return true
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return false
	}
	return hex.EncodeToString(hash.Sum(nil)) == digest
}

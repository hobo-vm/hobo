//go:build linux || darwin

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sync"
)

// Tools are executables the host serves for the agent to run, fetched on first use each boot
// like the agent itself, and again when the host's digest of the tool (`toolDigest`) differs
// from the one fetched, as after hobo is updated under a running VM, so they match the hobo
// asking for them. An exec request naming
// one (`tool`) has it in place before its command runs. Only `ui` exists: hobo-ui, the macOS
// guests' accessibility driver behind `hobo ui` (designs/hobo-ui.md).
var tools = map[string]bool{"ui": true}

var toolLock sync.Mutex

// toolPath is where a fetched tool lives: root's, in the run directory a boot clears.
func toolPath(name string) string {
	return filepath.Join(agentRunDirectory, "hobo-"+name)
}

// ensureTool fetches the tool if this boot hasn't, or if what it fetched isn't `digest` (the
// host's SHA-256 of it, hex; empty to take whatever is there), and makes its state directory
// for user: `<run directory>/<tool>/<user>`, theirs alone, which hobo-ui keeps its refs in.
func ensureTool(name, digest, user string) error {
	if !tools[name] {
		return fmt.Errorf("unknown tool %q", name)
	}
	toolLock.Lock()
	defer toolLock.Unlock()
	path := toolPath(name)
	if !hasTool(path, digest) {
		if err := fetchExecutable(name+"-"+runtime.GOOS+"-"+runtime.GOARCH, path); err != nil {
			return fmt.Errorf("fetching hobo-%s from the host: %w", name, err)
		}
	}
	who, err := lookupAccount(user)
	if err != nil {
		return err
	}
	// The tool's directory is everyone's to look in; each user's within it, theirs alone.
	parent := filepath.Join(agentRunDirectory, name)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return err
	}
	state := filepath.Join(parent, user)
	if err := os.MkdirAll(state, 0o700); err != nil {
		return err
	}
	return os.Chown(state, int(who.uid), int(who.gid))
}

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

//go:build linux || darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

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


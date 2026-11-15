package main

import (
	"fmt"
	"path/filepath"
	"runtime"
)

// toolPath is where a fetched tool lives: an exe in the agent's run directory, SYSTEM's. It
// outlives a boot, but ensureTool's digest check replaces one older than the host's.
func toolPath(name string) string {
	return filepath.Join(agentRunDirectory, "hobo-"+name+".exe")
}

// ensureTool fetches the tool if this boot hasn't, or if what it fetched isn't `digest` (the
// host's SHA-256 of it, hex; empty to take whatever is there). Windows tools keep no state of
// their own, so there is no per-user directory.
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
	return nil
}

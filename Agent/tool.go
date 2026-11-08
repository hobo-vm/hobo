//go:build linux || darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
)

// Tools are executables the host serves for the agent to run, fetched on first use each boot
// like the agent itself, so they always match the hobo asking for them. An exec request naming
// one (`tool`) has it in place before its command runs. Only `ui` exists: hobo-ui, the macOS
// guests' accessibility driver behind `hobo ui` (designs/hobo-ui.md).
var tools = map[string]bool{"ui": true}

var toolLock sync.Mutex

// toolPath is where a fetched tool lives: root's, in the run directory a boot clears.
func toolPath(name string) string {
	return filepath.Join(agentRunDirectory, "hobo-"+name)
}

// ensureTool fetches the tool if this boot hasn't, and makes its state directory for user:
// `<run directory>/<tool>/<user>`, theirs alone, which hobo-ui keeps its refs in.
func ensureTool(name, user string) error {
	if !tools[name] {
		return fmt.Errorf("unknown tool %q", name)
	}
	toolLock.Lock()
	defer toolLock.Unlock()
	path := toolPath(name)
	if _, err := os.Stat(path); err != nil {
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

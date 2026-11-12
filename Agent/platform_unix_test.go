//go:build linux || darwin

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// What the host reports is a shell's status: 128 + the signal for a command killed by one.
func TestExitStatusIsAShells(t *testing.T) {
	for script, want := range map[string]int32{"exit 0": 0, "exit 3": 3, "kill -TERM $$": 128 + 15} {
		status, ok := exitStatus(exec.Command("/bin/sh", "-c", script).Run())
		if !ok || status != want {
			t.Errorf("%s: %d %v, wanted %d", script, status, ok, want)
		}
	}
	if _, ok := exitStatus(errors.New("couldn't start")); ok {
		t.Error("a start failure read as a status")
	}
}

// Only the tools the host serves can be asked for; anything else fails before reaching the host.
func TestEnsureToolRefusesUnknownTools(t *testing.T) {
	if err := ensureTool("nope", "", "nobody"); err == nil || err.Error() != `unknown tool "nope"` {
		t.Fatalf("ensureTool(nope) = %v", err)
	}
}

// A tool fetched before hobo was updated is fetched again: the host's digest no longer matches.
func TestHasToolChecksTheHostsDigest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hobo-ui")
	if hasTool(path, "") {
		t.Error("a missing tool counted as there")
	}
	if err := os.WriteFile(path, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("old"))
	if !hasTool(path, "") || !hasTool(path, hex.EncodeToString(sum[:])) {
		t.Error("the tool that's there, unchecked or matching, didn't count")
	}
	newer := sha256.Sum256([]byte("new"))
	if hasTool(path, hex.EncodeToString(newer[:])) {
		t.Error("a tool with another digest counted as the host's")
	}
}

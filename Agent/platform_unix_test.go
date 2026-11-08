//go:build linux || darwin

package main

import (
	"errors"
	"os/exec"
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

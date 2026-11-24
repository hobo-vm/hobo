//go:build linux || darwin

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// lockedBuffer is a command's output, written from outputRelay's goroutines.
type lockedBuffer struct {
	mutex  sync.Mutex
	buffer bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.buffer.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.buffer.String()
}

// launchShell runs script in a process group of its own, as start does, and ends it with the test.
func launchShell(t *testing.T, script string, stdout, stderr *lockedBuffer) process {
	t.Helper()
	cmd := exec.Command("/bin/sh", "-c", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	proc, err := launch(cmd, commandSpec{stdout: stdout, stderr: stderr})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) })
	return proc
}

// A background process that keeps the command's output open (here a subshell: only what follows
// the && is redirected) doesn't hold the exec: it answers once the command has exited, and the
// process runs on.
func TestACommandsBackgroundProcessDoesntHoldItsExec(t *testing.T) {
	var stdout, stderr lockedBuffer
	began := time.Now()
	proc := launchShell(t, "true && sleep 60 >/dev/null 2>&1 & echo $!; echo oops >&2; exit 3", &stdout, &stderr)
	status, err := proc.Wait()
	if err != nil || status != 3 {
		t.Fatalf("status %d, %v", status, err)
	}
	if waited := time.Since(began); waited > 10*time.Second {
		t.Fatalf("answered after %v", waited)
	}
	if stderr.String() != "oops\n" {
		t.Fatalf("stderr %q", stderr.String())
	}
	pid := strings.TrimSpace(stdout.String())
	if err := exec.Command("/bin/kill", "-0", pid).Run(); err != nil {
		t.Fatalf("the background process %q is gone: %v", pid, err)
	}
}

// All of a command's output is passed on, however much there is, and what a process it left
// running writes after the grace is dropped without stopping that process.
func TestOutputIsWholeAndWhatComesAfterTheGraceIsDropped(t *testing.T) {
	grace := outputGrace
	outputGrace = 200 * time.Millisecond
	defer func() { outputGrace = grace }()
	var stdout, stderr lockedBuffer
	marker := filepath.Join(t.TempDir(), "done")
	proc := launchShell(t, "(sleep 1; echo late; touch "+marker+") & head -c 1000000 /dev/zero | tr '\\0' x", &stdout, &stderr)
	if status, err := proc.Wait(); err != nil || status != 0 {
		t.Fatalf("status %d, %v", status, err)
	}
	if got := stdout.String(); got != strings.Repeat("x", 1000000) {
		t.Fatalf("%d bytes of output, ending %q", len(got), got[max(0, len(got)-10):])
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the background process didn't finish")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if strings.Contains(stdout.String(), "late") {
		t.Fatal("output from after the exec answered was passed on")
	}
}

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

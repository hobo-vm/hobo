package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRemoveTakesFilesAndWholeDirectories(t *testing.T) {
	home := t.TempDir()
	write(t, filepath.Join(home, "app/Contents/MacOS/app"), "a")
	write(t, filepath.Join(home, "note"), "n")
	if err := os.Symlink("/nonexistent", filepath.Join(home, "dangling")); err != nil {
		t.Fatal(err)
	}
	var messages strings.Builder
	// Relative paths are from home; a dangling symlink is itself removed.
	if err := removePaths(&messages, home, []string{"app", filepath.Join(home, "note"), "dangling"}, false); err != nil {
		t.Fatalf("%v: %s", err, messages.String())
	}
	for _, name := range []string{"app", "note", "dangling"} {
		if _, err := os.Lstat(filepath.Join(home, name)); !os.IsNotExist(err) {
			t.Fatalf("%s is still there", name)
		}
	}
}

func TestRemoveFailsForAMissingPathUnlessForced(t *testing.T) {
	home := t.TempDir()
	write(t, filepath.Join(home, "keep-going"), "k")
	var messages strings.Builder
	err := removePaths(&messages, home, []string{"missing", "keep-going"}, false)
	if err != errReported || !strings.Contains(messages.String(), "missing: no such file or directory") {
		t.Fatalf("%v: %q", err, messages.String())
	}
	// The rest are still removed, as rm does.
	if _, err := os.Lstat(filepath.Join(home, "keep-going")); !os.IsNotExist(err) {
		t.Fatal("a path after the missing one was left")
	}
	messages.Reset()
	if err := removePaths(&messages, home, []string{"missing"}, true); err != nil || messages.Len() != 0 {
		t.Fatalf("forced: %v: %q", err, messages.String())
	}
}

func TestRemoveRefusesTheRootAndTheHome(t *testing.T) {
	home := filepath.Join(t.TempDir(), "hobo")
	write(t, filepath.Join(home, "file"), "f")
	for path, want := range map[string]string{
		"/":                   "refusing to remove the filesystem root",
		".":                   "refusing to remove the home directory",
		home + "/":            "refusing to remove the home directory",
		strings.ToUpper(home): "refusing to remove", // macOS's filesystem ignores case
		"..":                  "refusing to remove a directory that holds the home directory",
		filepath.Dir(home):    "refusing to remove a directory that holds the home directory",
		"sub/../..":           "refusing to remove a directory that holds the home directory",
		"":                    "refusing an empty path",
	} {
		var messages strings.Builder
		if err := removePaths(&messages, home, []string{path}, true); err != errReported || !strings.Contains(messages.String(), want) {
			t.Errorf("%q: %v: %q", path, err, messages.String())
		}
	}
	if read(t, filepath.Join(home, "file")) != "f" {
		t.Fatal("the home was touched")
	}
}

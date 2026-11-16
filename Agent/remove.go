package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// `hobo rm` inside the guest: runs as the request's user (the agent starts it with that user's
// credentials, from their home), so paths are removed with that user's rights and relative ones
// are from that home.

// removePaths removes each path, a directory with everything in it, as `rm -rf` would, except
// that a path that isn't there fails it unless force. It refuses the filesystem root, the user's
// home and what holds it. Like rm, a path it can't remove is reported and skipped, and fails it
// at the end.
func removePaths(messages io.Writer, home string, paths []string, force bool) error {
	failed := false
	for _, path := range paths {
		if err := removePath(home, path, force); err != nil {
			fmt.Fprintln(messages, err)
			failed = true
		}
	}
	if failed {
		return errReported
	}
	return nil
}

func removePath(home, path string, force bool) error {
	if path == "" {
		return fmt.Errorf("refusing an empty path")
	}
	absolute := path
	switch {
	case filepath.IsAbs(absolute):
	case filepath.VolumeName(absolute) == "" && (strings.HasPrefix(absolute, "/") || strings.HasPrefix(absolute, `\`)):
		// Rooted without a drive, as /tmp/x is on Windows: from the root of the home's drive, as
		// the file APIs (and `hobo cp`) take it, not from the home.
		absolute = filepath.VolumeName(home) + absolute
	default:
		absolute = filepath.Join(home, absolute)
	}
	absolute = filepath.Clean(absolute)
	if holds(absolute, home) {
		what := "a directory that holds the home directory"
		switch {
		case isRoot(absolute):
			what = "the filesystem root"
		case strings.EqualFold(absolute, filepath.Clean(home)):
			what = "the home directory"
		}
		return fmt.Errorf("%s: refusing to remove %s", path, what)
	}
	if _, err := os.Lstat(absolute); err != nil {
		if os.IsNotExist(err) {
			if force {
				return nil
			}
			return fmt.Errorf("%s: no such file or directory", path)
		}
		return err
	}
	return os.RemoveAll(absolute)
}

// holds says whether removing directory would remove path: it is path or an ancestor of it.
// Paths compare without regard to case, as macOS's and Windows's default filesystems do; on Linux
// that only refuses more.
func holds(directory, path string) bool {
	if isRoot(directory) {
		return true
	}
	directory, path = strings.ToLower(directory), strings.ToLower(filepath.Clean(path))
	return path == directory || strings.HasPrefix(path, directory+string(filepath.Separator))
}

// isRoot says whether a clean absolute path is a filesystem root: / or, on Windows, C:\.
func isRoot(path string) bool {
	return filepath.Dir(path) == path
}

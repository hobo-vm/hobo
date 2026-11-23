package main

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// `hobo cp` inside the guest, as scp would do it: these run as the copy's user (the agent starts
// them with that user's credentials, from their home), so files are read and written with that
// user's rights, and guest paths are taken as guestPath takes them.

// guestPath is where a guest path the user typed (the path of dev:<path>) is, for every command
// that takes one, so a guest operand names the same file whichever command it is given to. A
// leading ~ is home, since the shell leaves the ~ of dev:~/x alone and a literal ~ directory is
// never what was meant. A relative path is from home, and one rooted without a drive, as /tmp/x
// is on Windows, is from the root of home's drive, as the file APIs take it.
func guestPath(home, path string) string {
	switch {
	case path == "~" || strings.HasPrefix(path, "~/") || strings.HasPrefix(path, `~\`):
		path = filepath.Join(home, path[1:])
	case filepath.IsAbs(path):
	case filepath.VolumeName(path) == "" && (strings.HasPrefix(path, "/") || strings.HasPrefix(path, `\`)):
		path = filepath.VolumeName(home) + path
	default:
		path = filepath.Join(home, path)
	}
	return filepath.Clean(path)
}

// putTar extracts a tar stream from stdin. Its top-level entries are the sources' base names.
// Into a directory that exists they go in under those names; otherwise a single source becomes
// destination itself, as `scp a b` makes b. A source never lands on something of the other kind
// (a file on a directory or a directory on a file): that fails. Without replace a directory that
// is already there is merged into, as scp does; with it, what a source lands on is removed first.
// Unlike scp, a single directory onto a directory of its own name (a.app onto
// /Applications/a.app) is that directory, not a new one inside it, unless typed ends in a slash or
// names it as `.` or `~`; and the directories above a destination that isn't there are made, for
// a file as for a directory. The host does the same for a copy out of the guest (GuestAgent.get).
// typed is the destination as the user typed it, which guestPath resolves against home.
func putTar(input io.Reader, home, typed string, single, replace bool) error {
	destination := guestPath(home, typed)
	info, err := os.Stat(destination)
	intoDirectory := err == nil && info.IsDir()
	if !intoDirectory {
		switch {
		case endsInSeparator(typed):
			return fmt.Errorf("%s: no such directory", typed)
		case !single:
			return fmt.Errorf("%s: not a directory", typed)
		}
	}
	// What a source lands on is checked, and with replace removed, as its first entry arrives, so
	// a copy that brings nothing removes nothing.
	seen := map[string]bool{}
	madeParent := false
	reader := tar.NewReader(input)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		name, err := entryName(header.Name)
		if err != nil {
			return err
		}
		top, _, _ := strings.Cut(name, "/")
		// A source's first entry is the source itself.
		if !seen[top] {
			seen[top] = true
			isDirectory := header.Typeflag == tar.TypeDir
			// A single directory onto a directory of its own name becomes that directory. It is
			// matched against the destination as typed, not as resolved, so `.` or `~` naming a
			// directory that happens to share the source's name is still copied into.
			if single && isDirectory && !endsInSeparator(typed) && top == filepath.Base(typed) {
				intoDirectory = false
			}
			target := placement(destination, top, intoDirectory)
			if _, err := os.Lstat(target); err == nil {
				// A link counts as what it points at, so a copy merges through a link to a directory.
				info, err := os.Stat(target)
				if err := sameKind(target, err == nil && info.IsDir(), top, isDirectory); err != nil {
					return err
				}
				if replace {
					if err := os.RemoveAll(target); err != nil {
						return err
					}
				}
			}
		}
		// Made as the first entry arrives, so a copy that brings nothing makes nothing. A directory
		// source makes them itself; this is for a file.
		if !intoDirectory && !madeParent {
			madeParent = true
			if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
				return err
			}
		}
		if err := extract(header, reader, placement(destination, name, intoDirectory), destination, intoDirectory); err != nil {
			return err
		}
	}
}

// sameKind refuses a source landing on something of the other kind: a directory is never
// replaced by a file, or a file by a directory, with or without replace.
func sameKind(target string, targetIsDirectory bool, source string, sourceIsDirectory bool) error {
	switch {
	case targetIsDirectory && !sourceIsDirectory:
		return fmt.Errorf("%s: is a directory, and %s is not", target, source)
	case !targetIsDirectory && sourceIsDirectory:
		return fmt.Errorf("%s: is not a directory, and %s is", target, source)
	}
	return nil
}

// endsInSeparator is whether a typed path ends in a slash (or, on Windows, a backslash), which
// says it must be a directory to copy into.
func endsInSeparator(typed string) bool {
	return typed != "" && os.IsPathSeparator(typed[len(typed)-1])
}

// entryName checks that a tar entry stays inside where it is extracted.
func entryName(name string) (string, error) {
	clean := path.Clean(strings.TrimSuffix(name, "/"))
	if path.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, "../") || clean == "." {
		return "", fmt.Errorf("refusing tar entry %q", name)
	}
	return clean, nil
}

// placement is where the entry name lands: under destination, or, for a single source that
// becomes destination itself, with its top-level name replaced by destination.
func placement(destination, name string, intoDirectory bool) string {
	if !intoDirectory {
		_, name, _ = strings.Cut(name, "/")
	}
	return filepath.Join(destination, name)
}

func extract(header *tar.Header, reader io.Reader, target, destination string, intoDirectory bool) error {
	mode := fs.FileMode(header.Mode) & fs.ModePerm
	switch header.Typeflag {
	case tar.TypeDir:
		if err := os.MkdirAll(target, mode|0o700); err != nil {
			return err
		}
		return os.Chmod(target, mode)
	case tar.TypeReg:
		file, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(file, reader)
		if err := file.Close(); copyErr == nil {
			copyErr = err
		}
		return copyErr
	case tar.TypeSymlink:
		_ = os.Remove(target)
		return os.Symlink(header.Linkname, target)
	case tar.TypeLink:
		name, err := entryName(header.Linkname)
		if err != nil {
			return err
		}
		_ = os.Remove(target)
		return os.Link(placement(destination, name, intoDirectory), target)
	default:
		return nil // Devices, FIFOs and the like: scp doesn't copy them either.
	}
}

// getTar writes a tar stream of sources to output, each under its base name. Like scp, a missing
// source is reported and skipped, and fails the copy at the end. Each source is the path as typed,
// which guestPath resolves against home.
func getTar(output, messages io.Writer, home string, sources []string) error {
	writer := tar.NewWriter(output)
	failed := false
	for _, source := range sources {
		if err := addSource(writer, guestPath(home, source), source); err != nil {
			fmt.Fprintln(messages, err)
			failed = true
		}
	}
	if err := writer.Close(); err != nil {
		return err
	}
	if failed {
		return errReported
	}
	return nil
}

// errReported fails a copy or removal whose problems have already been reported, one per path.
var errReported = errors.New("")

// addSource adds the file at source, reporting a problem under typed, the path as the user typed it.
func addSource(writer *tar.Writer, source, typed string) error {
	// A source that is a symlink is copied as what it points to, as scp does.
	info, err := os.Stat(source)
	if err != nil {
		return fmt.Errorf("%s: no such file or directory", typed)
	}
	// guestPath has made source absolute and clean, so `.` and `..` still give one top-level entry.
	base := filepath.Base(source)
	if !info.IsDir() {
		return addEntry(writer, source, base, info)
	}
	// A filesystem root has no name to copy it under, and holds /dev and /proc, whose files never end.
	if filepath.Dir(source) == source {
		return fmt.Errorf("%s: is the filesystem root (copy a directory in it)", typed)
	}
	// Walked from what it resolves to, since the walk doesn't follow a symlink it starts at.
	root, err := filepath.EvalSymlinks(source)
	if err != nil {
		return err
	}
	return filepath.Walk(root, func(file string, info fs.FileInfo, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, file)
		if err != nil {
			return err
		}
		return addEntry(writer, file, filepath.ToSlash(filepath.Join(base, relative)), info)
	})
}

func addEntry(writer *tar.Writer, file, name string, info fs.FileInfo) error {
	link := ""
	if info.Mode()&fs.ModeSymlink != 0 {
		target, err := os.Readlink(file)
		if err != nil {
			return err
		}
		link = target
	} else if !info.Mode().IsRegular() && !info.IsDir() {
		return nil
	}
	header, err := tar.FileInfoHeader(info, link)
	if err != nil {
		return err
	}
	header.Name = name
	if info.IsDir() {
		header.Name += "/"
	}
	if err := writer.WriteHeader(header); err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return nil
	}
	f, err := os.Open(file)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(writer, f)
	return err
}

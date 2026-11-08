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
// them with that user's credentials), so files are read and written with that user's rights, and
// relative guest paths are from that user's home.

// putTar extracts a tar stream from stdin. Its top-level entries are the sources' base names.
// Into a directory that exists they go in under those names; otherwise a single source becomes
// destination itself, as `scp a b` makes b.
func putTar(input io.Reader, destination string, single bool) error {
	info, err := os.Stat(destination)
	intoDirectory := err == nil && info.IsDir()
	if !intoDirectory {
		switch {
		case strings.HasSuffix(destination, "/"):
			return fmt.Errorf("%s: no such directory", destination)
		case !single:
			return fmt.Errorf("%s: not a directory", destination)
		}
	}
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
		if err := extract(header, reader, placement(destination, name, intoDirectory), destination, intoDirectory); err != nil {
			return err
		}
	}
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
// source or a directory without recursive is reported and skipped, and fails the copy at the end.
func getTar(output, messages io.Writer, sources []string, recursive bool) error {
	writer := tar.NewWriter(output)
	failed := false
	for _, source := range sources {
		if err := addSource(writer, source, recursive); err != nil {
			fmt.Fprintln(messages, err)
			failed = true
		}
	}
	if err := writer.Close(); err != nil {
		return err
	}
	if failed {
		return errCopyFailed
	}
	return nil
}

// errCopyFailed fails a copy whose problems have already been reported, one per source.
var errCopyFailed = errors.New("")

func addSource(writer *tar.Writer, source string, recursive bool) error {
	// A source that is a symlink is copied as what it points to, as scp does.
	info, err := os.Stat(source)
	if err != nil {
		return fmt.Errorf("%s: no such file or directory", source)
	}
	base := filepath.Base(filepath.Clean(source))
	if !info.IsDir() {
		return addEntry(writer, source, base, info)
	}
	if !recursive {
		return fmt.Errorf("%s: is a directory (cp -r copies directories)", source)
	}
	return filepath.Walk(source, func(file string, info fs.FileInfo, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(source, file)
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

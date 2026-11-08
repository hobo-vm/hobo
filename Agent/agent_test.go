package main

import (
	"bufio"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFramesRoundTrip(t *testing.T) {
	var buffer bytes.Buffer
	frames := &frameWriter{w: &buffer}
	big := bytes.Repeat([]byte("x"), maxFrame+10)
	if err := frames.write(frameStdout, big); err != nil {
		t.Fatal(err)
	}
	if err := frames.exit(-3); err != nil {
		t.Fatal(err)
	}
	var got []byte
	for range 2 {
		kind, payload, err := readFrame(&buffer)
		if err != nil || kind != frameStdout {
			t.Fatalf("kind %q, err %v", kind, err)
		}
		got = append(got, payload...)
	}
	if !bytes.Equal(got, big) {
		t.Fatalf("got %d bytes back, wanted %d", len(got), len(big))
	}
	kind, payload, err := readFrame(&buffer)
	if err != nil || kind != frameExit || int32(uint32(payload[0])<<24|uint32(payload[1])<<16|uint32(payload[2])<<8|uint32(payload[3])) != -3 {
		t.Fatalf("exit frame %q %v %v", kind, payload, err)
	}
}

func TestRequestLineLeavesWhatFollows(t *testing.T) {
	var buffer bytes.Buffer
	buffer.WriteString(`{"version":1,"op":"put","destination":"d"}` + "\n")
	frames := &frameWriter{w: &buffer}
	_ = frames.write(frameData, []byte("abc"))
	_ = frames.write(frameData, nil)
	reader := bufio.NewReader(&buffer)
	req, err := readRequest(reader)
	if err != nil || req.Op != "put" || req.Destination != "d" {
		t.Fatalf("%+v %v", req, err)
	}
	data, err := io.ReadAll(&dataReader{r: reader})
	if err != nil || string(data) != "abc" {
		t.Fatalf("%q %v", data, err)
	}
}

func write(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o640); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// copyTree is get on one side and put on the other, as a host-to-host copy through the agent's tar.
func copyTree(t *testing.T, sources []string, destination string, recursive bool) (string, error) {
	t.Helper()
	var archive, messages bytes.Buffer
	getErr := getTar(&archive, &messages, sources, recursive)
	if err := putTar(&archive, destination, len(sources) == 1); err != nil {
		return messages.String(), err
	}
	return messages.String(), getErr
}

func TestCopyIntoExistingDirectory(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "src/tree/a.txt"), "a")
	write(t, filepath.Join(dir, "src/tree/sub/b.txt"), "b")
	write(t, filepath.Join(dir, "src/one.txt"), "one")
	if err := os.Symlink("a.txt", filepath.Join(dir, "src/tree/link")); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(dir, "dest")
	if err := os.Mkdir(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := copyTree(t, []string{filepath.Join(dir, "src/tree"), filepath.Join(dir, "src/one.txt")}, dest, true); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dest, "tree/sub/b.txt")) != "b" || read(t, filepath.Join(dest, "one.txt")) != "one" {
		t.Fatal("wrong contents")
	}
	if target, _ := os.Readlink(filepath.Join(dest, "tree/link")); target != "a.txt" {
		t.Fatalf("link points at %q", target)
	}
	if info, _ := os.Stat(filepath.Join(dest, "one.txt")); info.Mode().Perm() != 0o640 {
		t.Fatalf("mode %v", info.Mode())
	}
}

func TestCopySingleSourceBecomesDestination(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "tree/a.txt"), "a")
	write(t, filepath.Join(dir, "file"), "f")
	if _, err := copyTree(t, []string{filepath.Join(dir, "tree")}, filepath.Join(dir, "renamed"), true); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dir, "renamed/a.txt")) != "a" {
		t.Fatal("directory not renamed")
	}
	if _, err := copyTree(t, []string{filepath.Join(dir, "file")}, filepath.Join(dir, "copy"), false); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dir, "copy")) != "f" {
		t.Fatal("file not renamed")
	}
}

func TestCopyDotIsOneDirectory(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "home/a.txt"), "a")
	write(t, filepath.Join(dir, "home/b.txt"), "b")
	t.Chdir(filepath.Join(dir, "home"))
	if _, err := copyTree(t, []string{"."}, filepath.Join(dir, "copy"), true); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dir, "copy/a.txt")) != "a" || read(t, filepath.Join(dir, "copy/b.txt")) != "b" {
		t.Fatal("not every entry of . was copied")
	}
}

func TestCopyFailures(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "tree/a.txt"), "a")
	write(t, filepath.Join(dir, "file"), "f")
	messages, err := copyTree(t, []string{filepath.Join(dir, "tree")}, filepath.Join(dir, "out"), false)
	if err != errCopyFailed || !strings.Contains(messages, "is a directory") {
		t.Fatalf("directory without -r: %q %v", messages, err)
	}
	messages, err = copyTree(t, []string{filepath.Join(dir, "missing"), filepath.Join(dir, "file")}, dir, false)
	if err != errCopyFailed || !strings.Contains(messages, "no such file") || read(t, filepath.Join(dir, "file")) != "f" {
		t.Fatalf("missing source: %q %v", messages, err)
	}
	if _, err := copyTree(t, []string{filepath.Join(dir, "file"), filepath.Join(dir, "tree")}, filepath.Join(dir, "nowhere"), true); err == nil || !strings.Contains(err.Error(), "not a directory") {
		t.Fatalf("several sources into a file: %v", err)
	}
	if _, err := copyTree(t, []string{filepath.Join(dir, "file")}, filepath.Join(dir, "nodir")+"/", false); err == nil {
		t.Fatal("a trailing slash on a missing directory should fail")
	}
}

func TestEntryNamesStayInside(t *testing.T) {
	for _, name := range []string{"../x", "/etc/passwd", "a/../../x", "."} {
		if _, err := entryName(name); err == nil {
			t.Errorf("%q accepted", name)
		}
	}
	if name, err := entryName("a/./b/"); err != nil || name != "a/b" {
		t.Errorf("a/./b/: %q %v", name, err)
	}
}

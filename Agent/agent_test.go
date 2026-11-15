package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"io"
	"net"
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
	buffer.WriteString(`{"version":2,"op":"put","destination":"d"}` + "\n")
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
func copyTree(t *testing.T, sources []string, destination string) (string, error) {
	t.Helper()
	return copyTreeReplacing(t, sources, destination, false)
}

func copyTreeReplacing(t *testing.T, sources []string, destination string, replace bool) (string, error) {
	t.Helper()
	var archive, messages bytes.Buffer
	getErr := getTar(&archive, &messages, sources)
	if err := putTar(&archive, destination, len(sources) == 1, replace); err != nil {
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
	if _, err := copyTree(t, []string{filepath.Join(dir, "src/tree"), filepath.Join(dir, "src/one.txt")}, dest); err != nil {
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
	if _, err := copyTree(t, []string{filepath.Join(dir, "tree")}, filepath.Join(dir, "renamed")); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dir, "renamed/a.txt")) != "a" {
		t.Fatal("directory not renamed")
	}
	if _, err := copyTree(t, []string{filepath.Join(dir, "file")}, filepath.Join(dir, "copy")); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dir, "copy")) != "f" {
		t.Fatal("file not renamed")
	}
}

// Without replace a copy onto a directory merges into it, as scp does; with it, what each source
// lands on goes first, and the destination's other entries stay.
func TestCopyReplacesWhatASourceLandsOn(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "src/App/new.txt"), "new")
	write(t, filepath.Join(dir, "dest/App/stale.txt"), "stale")
	write(t, filepath.Join(dir, "dest/other.txt"), "other")
	source, dest := []string{filepath.Join(dir, "src/App")}, filepath.Join(dir, "dest")
	if _, err := copyTree(t, source, dest); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dest, "App/stale.txt")) != "stale" {
		t.Fatal("a plain copy should merge")
	}
	if _, err := copyTreeReplacing(t, source, dest, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dest, "App/stale.txt")); !os.IsNotExist(err) {
		t.Fatalf("stale file survived: %v", err)
	}
	if read(t, filepath.Join(dest, "App/new.txt")) != "new" || read(t, filepath.Join(dest, "other.txt")) != "other" {
		t.Fatal("wrong contents")
	}
	// A single directory onto a file takes the file's place.
	write(t, filepath.Join(dir, "plain"), "f")
	if _, err := copyTreeReplacing(t, source, filepath.Join(dir, "plain"), true); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dir, "plain/new.txt")) != "new" {
		t.Fatal("the file was not replaced")
	}
}

// The host's tar sends an empty archive when it can't read its source: the destination stays.
func TestCopyReplaceKeepsTheDestinationWhenNothingArrives(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "kept"), "kept")
	var archive bytes.Buffer
	if err := tar.NewWriter(&archive).Close(); err != nil {
		t.Fatal(err)
	}
	if err := putTar(&archive, filepath.Join(dir, "kept"), true, true); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dir, "kept")) != "kept" {
		t.Fatal("the destination was removed")
	}
}

func TestCopyDotIsOneDirectory(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "home/a.txt"), "a")
	write(t, filepath.Join(dir, "home/b.txt"), "b")
	t.Chdir(filepath.Join(dir, "home"))
	if _, err := copyTree(t, []string{"."}, filepath.Join(dir, "copy")); err != nil {
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
	messages, err := copyTree(t, []string{filepath.Join(dir, "missing"), filepath.Join(dir, "file")}, dir)
	if err != errCopyFailed || !strings.Contains(messages, "no such file") || read(t, filepath.Join(dir, "file")) != "f" {
		t.Fatalf("missing source: %q %v", messages, err)
	}
	if _, err := copyTree(t, []string{filepath.Join(dir, "file"), filepath.Join(dir, "tree")}, filepath.Join(dir, "nowhere")); err == nil || !strings.Contains(err.Error(), "not a directory") {
		t.Fatalf("several sources into a file: %v", err)
	}
	if _, err := copyTree(t, []string{filepath.Join(dir, "file")}, filepath.Join(dir, "nodir")+"/"); err == nil {
		t.Fatal("a trailing slash on a missing directory should fail")
	}
	if err := os.Mkdir(filepath.Join(dir, "out"), 0o755); err != nil {
		t.Fatal(err)
	}
	messages, err = copyTree(t, []string{"/", filepath.Join(dir, "file")}, filepath.Join(dir, "out"))
	if err != errCopyFailed || !strings.Contains(messages, "/: is the filesystem root") || read(t, filepath.Join(dir, "out/file")) != "f" {
		t.Fatalf("root source: %q %v", messages, err)
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

// ask sends one request line to handle, as the host would, and returns the frame that ends it.
func ask(t *testing.T, line string) (byte, []byte) {
	t.Helper()
	host, agent := net.Pipe()
	defer host.Close()
	go handle(agent)
	go func() { _, _ = host.Write([]byte(line + "\n")) }()
	kind, payload, err := readFrame(host)
	if err != nil {
		t.Fatal(err)
	}
	return kind, payload
}

func TestHandleAnswersAPingAndRefusesWhatItCantDo(t *testing.T) {
	if kind, payload := ask(t, `{"version":2,"op":"ping"}`); kind != frameExit || !bytes.Equal(payload, []byte{0, 0, 0, 0}) {
		t.Fatalf("ping: %q %v", kind, payload)
	}
	// An agent left running across a host upgrade says so, rather than misreading the request.
	if kind, payload := ask(t, `{"version":3,"op":"ping"}`); kind != frameError || !strings.Contains(string(payload), "protocol 2, not 3") {
		t.Fatalf("version: %q %q", kind, payload)
	}
	if kind, payload := ask(t, `{"version":2,"op":"shell"}`); kind != frameError || !strings.Contains(string(payload), `unknown request "shell"`) {
		t.Fatalf("op: %q %q", kind, payload)
	}
	if kind, _ := ask(t, `not json`); kind != frameError {
		t.Fatalf("bad line: %q", kind)
	}
}

func TestDataReaderRejectsAnotherFrame(t *testing.T) {
	var buffer bytes.Buffer
	_ = (&frameWriter{w: &buffer}).write(frameStdout, []byte("x"))
	if _, err := io.ReadAll(&dataReader{r: &buffer}); err == nil {
		t.Fatal("a stdout frame read as data")
	}
}

func TestStdinFramesReadAsAnExecsInputUpToTheEmptyOne(t *testing.T) {
	var buffer bytes.Buffer
	frames := &frameWriter{w: &buffer}
	_ = frames.write(frameStdin, []byte("one\n"))
	_ = frames.write(frameStdin, []byte("two\n"))
	_ = frames.write(frameStdin, nil)
	_ = frames.write(frameData, []byte("after"))
	input, err := io.ReadAll(&dataReader{r: &buffer, kind: frameStdin})
	if err != nil || string(input) != "one\ntwo\n" {
		t.Fatalf("%q %v", input, err)
	}
	if buffer.Len() == 0 {
		t.Fatal("read past the end of the input")
	}
}

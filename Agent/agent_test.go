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
	"time"
)

func TestFramesRoundTrip(t *testing.T) {
	var buffer bytes.Buffer
	frames := &frameWriter{w: &buffer}
	// One byte more than two full frames, so it goes out as three.
	big := bytes.Repeat([]byte("x"), 2*maxWrite+1)
	if err := frames.write(frameStdout, big); err != nil {
		t.Fatal(err)
	}
	if err := frames.exit(-3); err != nil {
		t.Fatal(err)
	}
	var got []byte
	for range 3 {
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
	getErr := getTar(&archive, &messages, "/", sources)
	if err := putTar(&archive, "/", destination, len(sources) == 1, replace); err != nil {
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
}

// A source never lands on something of the other kind, with or without replace: the copy fails
// and what was there stays.
func TestCopyRefusesToSwapAFileAndADirectory(t *testing.T) {
	for _, replace := range []bool{false, true} {
		dir := t.TempDir()
		write(t, filepath.Join(dir, "src/tree/a.txt"), "a")
		write(t, filepath.Join(dir, "src/notes"), "file")
		write(t, filepath.Join(dir, "plain"), "plain")
		write(t, filepath.Join(dir, "dest/notes/kept.txt"), "kept")
		write(t, filepath.Join(dir, "dest/tree"), "tree file")
		cases := []struct{ source, destination, kept string }{
			{"src/tree", "plain", "plain"},               // a directory onto a file
			{"src/tree", "dest", "dest/tree"},            // a directory onto a file inside it
			{"src/notes", "dest", "dest/notes/kept.txt"}, // a file onto a directory inside it
		}
		for _, c := range cases {
			_, err := copyTreeReplacing(t, []string{filepath.Join(dir, c.source)}, filepath.Join(dir, c.destination), replace)
			if err == nil || !strings.Contains(err.Error(), "directory") {
				t.Fatalf("replace %v, %s onto %s: %v", replace, c.source, c.destination, err)
			}
			if _, err := os.Stat(filepath.Join(dir, c.kept)); err != nil {
				t.Fatalf("replace %v, %s onto %s: %s went: %v", replace, c.source, c.destination, c.kept, err)
			}
		}
	}
}

// A file onto a directory of its own name goes inside it, as scp puts it: only a directory is
// that directory.
func TestCopyAFileOntoADirectoryOfItsOwnNameGoesInside(t *testing.T) {
	for _, replace := range []bool{false, true} {
		dir := t.TempDir()
		write(t, filepath.Join(dir, "src/notes"), "new")
		write(t, filepath.Join(dir, "dest/notes/kept.txt"), "kept")
		if _, err := copyTreeReplacing(t, []string{filepath.Join(dir, "src/notes")}, filepath.Join(dir, "dest/notes"), replace); err != nil {
			t.Fatal(err)
		}
		if read(t, filepath.Join(dir, "dest/notes/notes")) != "new" || read(t, filepath.Join(dir, "dest/notes/kept.txt")) != "kept" {
			t.Fatalf("replace %v: wrong contents", replace)
		}
	}
}

// A single source onto a directory of its own name is that directory, so copying a rebuilt
// App.app onto /Applications/App.app replaces or merges into it rather than nesting a second
// App.app inside; a trailing slash still copies into it.
func TestCopyOntoADirectoryOfItsOwnName(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "src/App.app/new.txt"), "new")
	write(t, filepath.Join(dir, "dest/App.app/stale.txt"), "stale")
	source, dest := []string{filepath.Join(dir, "src/App.app")}, filepath.Join(dir, "dest/App.app")
	if _, err := copyTree(t, source, dest); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dest, "new.txt")) != "new" || read(t, filepath.Join(dest, "stale.txt")) != "stale" {
		t.Fatal("a plain copy should merge into the directory itself")
	}
	if _, err := copyTreeReplacing(t, source, dest, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dest, "stale.txt")); !os.IsNotExist(err) {
		t.Fatalf("stale file survived: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, "App.app")); !os.IsNotExist(err) {
		t.Fatalf("copied inside the destination: %v", err)
	}
	if read(t, filepath.Join(dest, "new.txt")) != "new" {
		t.Fatal("wrong contents")
	}
	if _, err := copyTree(t, source, dest+"/"); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dest, "App.app/new.txt")) != "new" {
		t.Fatal("a trailing slash should copy into the directory")
	}
	// Named by `.`, it is copied into too, though the directory shares the source's name.
	if _, err := copyTreeReplacing(t, source, dest+"/.", true); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dest, "new.txt")) != "new" || read(t, filepath.Join(dest, "App.app/new.txt")) != "new" {
		t.Fatal("a destination of . should copy into the directory")
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
	if err := putTar(&archive, dir, "kept", true, true); err != nil {
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
	var archive, messages bytes.Buffer
	if err := getTar(&archive, &messages, filepath.Join(dir, "home"), []string{"."}); err != nil {
		t.Fatalf("%v: %s", err, messages.String())
	}
	if err := putTar(&archive, dir, "copy", true, false); err != nil {
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
	if err != errReported || !strings.Contains(messages, "no such file") || read(t, filepath.Join(dir, "file")) != "f" {
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
	if err != errReported || !strings.Contains(messages, "/: is the filesystem root") || read(t, filepath.Join(dir, "out/file")) != "f" {
		t.Fatalf("root source: %q %v", messages, err)
	}
}

func TestCopyTakesTildeAsTheHomeBothWays(t *testing.T) {
	home := t.TempDir()
	write(t, filepath.Join(home, "Apps/MyApp.app/Contents/app"), "a")
	if err := os.Mkdir(filepath.Join(home, "Out"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Out of the guest: ~/Apps/MyApp.app is home's, as `hobo rm` takes it.
	var archive, messages bytes.Buffer
	if err := getTar(&archive, &messages, home, []string{"~/Apps/MyApp.app"}); err != nil {
		t.Fatalf("%v: %s", err, messages.String())
	}
	// Into the guest: ~/Out/ is home's Out, not a literal ~ directory.
	if err := putTar(&archive, home, "~/Out/", true, false); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(home, "Out/MyApp.app/Contents/app")) != "a" {
		t.Fatal("~/ was not taken as the home")
	}
	if _, err := os.Lstat(filepath.Join(home, "~")); !os.IsNotExist(err) {
		t.Fatal("a literal ~ directory was made")
	}
	// A missing ~ path is reported as typed.
	archive.Reset()
	messages.Reset()
	if err := getTar(&archive, &messages, home, []string{"~/missing"}); err != errReported || !strings.Contains(messages.String(), "~/missing: no such file") {
		t.Fatalf("missing source: %q %v", messages.String(), err)
	}
}

func TestPutMakesTheDirectoriesAboveAFileThatIsntThere(t *testing.T) {
	home := t.TempDir()
	write(t, filepath.Join(home, "agent.plist"), "p")
	var archive, messages bytes.Buffer
	if err := getTar(&archive, &messages, home, []string{"agent.plist"}); err != nil {
		t.Fatalf("%v: %s", err, messages.String())
	}
	if err := putTar(&archive, home, "Library/LaunchAgents/agent.plist", true, false); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(home, "Library/LaunchAgents/agent.plist")) != "p" {
		t.Fatal("the file was not copied under the directories it names")
	}
	// A destination that must be a directory is still not made.
	archive.Reset()
	if err := putTar(&archive, home, "Missing/Deeper/", true, false); err == nil || !strings.Contains(err.Error(), "no such directory") {
		t.Fatalf("trailing slash: %v", err)
	}
}

func TestCopyFollowsASourceSymlinkToADirectory(t *testing.T) {
	home := t.TempDir()
	write(t, filepath.Join(home, "real/f"), "f")
	if err := os.Symlink("real", filepath.Join(home, "link")); err != nil {
		t.Fatal(err)
	}
	for _, source := range []string{"link", "link/"} {
		destination := filepath.Join(t.TempDir(), "copy")
		var archive, messages bytes.Buffer
		if err := getTar(&archive, &messages, home, []string{source}); err != nil {
			t.Fatalf("%s: %v: %s", source, err, messages.String())
		}
		if err := putTar(&archive, home, destination, true, false); err != nil {
			t.Fatal(err)
		}
		if read(t, filepath.Join(destination, "f")) != "f" {
			t.Fatalf("%s was not copied as the directory it points to", source)
		}
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

// exitedProcess has already exited, with status 3, having read none of its input.
type exitedProcess struct{ input io.WriteCloser }

func (p exitedProcess) Stdin() io.WriteCloser { return p.input }
func (exitedProcess) Wait() (int32, error)    { return 3, nil }
func (exitedProcess) Terminate()              {}

type discardCloser struct{}

func (discardCloser) Write(p []byte) (int, error) { return len(p), nil }
func (discardCloser) Close() error                { return nil }

func TestAnExecThatExitsBeforeItsInputEndsAnswersAtOnce(t *testing.T) {
	host, agent := net.Pipe()
	defer host.Close()
	defer agent.Close()
	proc := exitedProcess{discardCloser{}}
	go run(proc, agent, &frameWriter{w: agent}, func() {
		// The host sends no more input until it has an answer.
		_, _ = io.Copy(proc.Stdin(), &dataReader{r: agent, kind: frameStdin})
	}, false, nil)
	done := make(chan struct{})
	var kind byte
	var payload []byte
	go func() {
		kind, payload, _ = readFrame(host)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("no answer while the host waits to send more input")
	}
	if kind != frameExit || !bytes.Equal(payload, []byte{0, 0, 0, 3}) {
		t.Fatalf("%q %v", kind, payload)
	}
}

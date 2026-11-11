//go:build linux || darwin

package main

import (
	"io"
	"os"
	"os/exec"
	"os/user"
	"syscall"
	"time"
)

// Where the stub puts the agent it fetched: a fresh copy every boot, never on the guest's disk
// for long (Linux's /run is tmpfs).
var agentRunDirectory = "/run/hobo-agent"

const agentExecutableName = "hobo-agent"

// prepareStub has nothing to do: the service manager logs the stub's output.
func prepareStub() {}

func execAgent(path string) error {
	return syscall.Exec(path, []string{path, "serve"}, os.Environ())
}

// account is what a command runs as: what sshd would set up for a login.
type account struct {
	name  string
	uid   uint32
	gid   uint32
	home  string
	shell string
	// What os/user found, where the platform asks it (macOS).
	lookedUp *user.User
}

// environment is a login's: sshd's variables, and the PATH the system's profile builds on.
func (a account) environment() []string {
	env := []string{
		"HOME=" + a.home, "USER=" + a.name, "LOGNAME=" + a.name, "SHELL=" + a.shell,
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
	}
	env = append(env, platformEnvironment(a)...)
	return env
}

// command runs line in the account's login shell, in a process group of its own so a cancel
// reaches everything it started.
func (a account) command(line string) *exec.Cmd {
	return a.loginCommand([]string{a.shell, "-l", "-c", line})
}

// login is `hobo-agent login <user> <argv...>`: it becomes the user and execs argv, for a platform
// whose loginCommand has to start somewhere as root first (macOS's `launchctl asuser`).
func login(name string, argv []string) error {
	a, err := lookupAccount(name)
	if err != nil {
		return err
	}
	var groups []int
	for _, gid := range a.groups() {
		groups = append(groups, int(gid))
	}
	if err := syscall.Setgroups(groups); err != nil {
		return err
	}
	if err := syscall.Setgid(int(a.gid)); err != nil {
		return err
	}
	if err := syscall.Setuid(int(a.uid)); err != nil {
		return err
	}
	return syscall.Exec(argv[0], argv, os.Environ())
}

// configure makes cmd run as the account, from its home, with its login environment.
func (a account) configure(cmd *exec.Cmd) {
	cmd.Dir = a.home
	cmd.Env = a.environment()
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setpgid:    true,
		Credential: &syscall.Credential{Uid: a.uid, Gid: a.gid, Groups: a.groups()},
	}
}

// start runs spec as its user: a command line in their login shell, or this binary's own put, get
// or clipboard.
func start(spec commandSpec) (process, error) {
	who, err := lookupAccount(spec.user)
	if err != nil {
		return nil, err
	}
	var cmd *exec.Cmd
	switch {
	case spec.self == nil:
		cmd = who.command(spec.line)
	case spec.desktop:
		if cmd, err = who.desktopCommand(append([]string{selfPath()}, spec.self...)); err != nil {
			return nil, err
		}
	default:
		cmd = exec.Command(selfPath(), spec.self...)
		who.configure(cmd)
	}
	cmd.Stdout = spec.stdout
	cmd.Stderr = spec.stderr
	proc := &unixProcess{cmd: cmd, exited: make(chan struct{})}
	if spec.stdin {
		if proc.stdin, err = cmd.StdinPipe(); err != nil {
			return nil, err
		}
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return proc, nil
}

type unixProcess struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	exited chan struct{}
}

func (p *unixProcess) Stdin() io.WriteCloser { return p.stdin }

func (p *unixProcess) Wait() (int32, error) {
	err := p.cmd.Wait()
	close(p.exited)
	status, ok := exitStatus(err)
	if !ok {
		return 0, err
	}
	return status, nil
}

func (p *unixProcess) Terminate() { terminate(p.cmd, p.exited) }

// terminate ends cmd's process group: SIGTERM, and SIGKILL if it is still there after a grace.
func terminate(cmd *exec.Cmd, exited <-chan struct{}) {
	pgid := cmd.Process.Pid
	_ = syscall.Kill(-pgid, syscall.SIGTERM)
	select {
	case <-exited:
	case <-time.After(5 * time.Second):
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
	}
}

// exitStatus is the status a shell would report: 128 + the signal for a command killed by one.
func exitStatus(err error) (int32, bool) {
	if err == nil {
		return 0, true
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
			if status.Signaled() {
				return 128 + int32(status.Signal()), true
			}
			return int32(status.ExitStatus()), true
		}
	}
	return 0, false
}

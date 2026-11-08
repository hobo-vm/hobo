//go:build linux || darwin

package main

import (
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
	cmd := exec.Command(a.shell, "-l", "-c", line)
	a.configure(cmd)
	return cmd
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

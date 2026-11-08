package main

import (
	"fmt"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"syscall"
)

func init() {
	// macOS has no /run.
	agentRunDirectory = "/var/run/hobo-agent"
}

func platformEnvironment(a account) []string {
	return []string{"LANG=en_US.UTF-8"}
}

// loginCommand runs argv as the account in its launchd bootstrap: the desktop's (Aqua) once the
// user is logged in. A daemon's children are in the System bootstrap, where much of a user's
// world is missing: nohup fails ("can't detach from console"), for one. SSH logins got a session
// of their own from pam_launchd, which has no public API; `launchctl asuser` needs root, so it
// starts `hobo-agent login`, which then becomes the user. Both stay in the process group.
func (a account) loginCommand(argv []string) *exec.Cmd {
	args := append([]string{"asuser", strconv.FormatUint(uint64(a.uid), 10), selfPath(), "login", a.name}, argv...)
	cmd := exec.Command("/bin/launchctl", args...)
	cmd.Dir = a.home
	cmd.Env = a.environment()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

// lookupAccount asks Directory Services, which holds macOS's local users (/etc/passwd doesn't):
// os/user for the IDs and home, and dscl for the shell, which os/user doesn't give.
func lookupAccount(name string) (account, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return account{}, err
	}
	uid, err1 := strconv.ParseUint(u.Uid, 10, 32)
	gid, err2 := strconv.ParseUint(u.Gid, 10, 32)
	if err1 != nil || err2 != nil {
		return account{}, fmt.Errorf("bad IDs for %s", name)
	}
	shell := "/bin/zsh"
	if out, err := exec.Command("/usr/bin/dscl", ".", "-read", "/Users/"+name, "UserShell").Output(); err == nil {
		if _, value, ok := strings.Cut(strings.TrimSpace(string(out)), "UserShell: "); ok && value != "" {
			shell = value
		}
	}
	return account{name: name, uid: uint32(uid), gid: uint32(gid), home: u.HomeDir, shell: shell, lookedUp: u}, nil
}

func (a account) groups() []uint32 {
	groups := []uint32{a.gid}
	if a.lookedUp == nil {
		return groups
	}
	ids, err := a.lookedUp.GroupIds()
	if err != nil {
		return groups
	}
	for _, id := range ids {
		if gid, err := strconv.ParseUint(id, 10, 32); err == nil && uint32(gid) != a.gid {
			groups = append(groups, uint32(gid))
		}
	}
	return groups
}

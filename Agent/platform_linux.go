package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// platformEnvironment adds what pam_systemd gives an SSH login: the user's runtime directory,
// which `systemctl --user` (and with it `exec --gui`) needs to find the user's manager. It is set
// even before the directory exists: `exec --gui` may start before the desktop login creates it,
// and waits for the session.
func platformEnvironment(a account) []string {
	runtime := fmt.Sprintf("/run/user/%d", a.uid)
	return []string{"LANG=C.UTF-8", "XDG_RUNTIME_DIR=" + runtime, "DBUS_SESSION_BUS_ADDRESS=unix:path=" + runtime + "/bus"}
}

// loginCommand runs argv as the account, as sshd would.
func (a account) loginCommand(argv []string) *exec.Cmd {
	cmd := exec.Command(argv[0], argv[1:]...)
	a.configure(cmd)
	return cmd
}

// lookupAccount reads /etc/passwd: os/user gives no shell, and a static build has no libc to ask.
func lookupAccount(name string) (account, error) {
	file, err := os.Open("/etc/passwd")
	if err != nil {
		return account{}, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), ":")
		if len(fields) < 7 || fields[0] != name {
			continue
		}
		uid, err1 := strconv.ParseUint(fields[2], 10, 32)
		gid, err2 := strconv.ParseUint(fields[3], 10, 32)
		if err1 != nil || err2 != nil {
			return account{}, fmt.Errorf("/etc/passwd has a bad entry for %s", name)
		}
		return account{name: name, uid: uint32(uid), gid: uint32(gid), home: fields[5], shell: fields[6]}, nil
	}
	return account{}, fmt.Errorf("no user %s in /etc/passwd", name)
}

// groups lists the account's supplementary groups from /etc/group.
func (a account) groups() []uint32 {
	groups := []uint32{a.gid}
	file, err := os.Open("/etc/group")
	if err != nil {
		return groups
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), ":")
		if len(fields) < 4 {
			continue
		}
		for _, member := range strings.Split(fields[3], ",") {
			if member == a.name {
				if gid, err := strconv.ParseUint(fields[2], 10, 32); err == nil {
					groups = append(groups, uint32(gid))
				}
			}
		}
	}
	return groups
}

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

// Where the stub puts the agent it fetched, beside itself (C:\ProgramData\Hobo\hobo-agent.exe).
var agentRunDirectory = `C:\ProgramData\Hobo\agent`

const agentExecutableName = "hobo-agent.exe"

// The stub's log: a scheduled task has nowhere for its output to go.
const stubLogPath = `C:\ProgramData\Hobo\hobo-agent.log`

// The Vagrant convention's password, which setup.ps1 gave vagrant and auto-login uses too. Root
// on the other platforms becomes the user without one; Windows wants it for a logon of its own.
const windowsPassword = "vagrant"

// As GUISession has it: how long `exec --gui` waits for the desktop, and what it exits with then.
const (
	desktopWaitSeconds       = 60
	desktopUnavailableStatus = 125
)

var (
	advapi32                    = syscall.NewLazyDLL("advapi32.dll")
	procLogonUserW              = advapi32.NewProc("LogonUserW")
	procCreateProcessWithTokenW = advapi32.NewProc("CreateProcessWithTokenW")
	kernel32                    = syscall.NewLazyDLL("kernel32.dll")
	procActiveConsoleSession    = kernel32.NewProc("WTSGetActiveConsoleSessionId")
	procProcessIdToSessionId    = kernel32.NewProc("ProcessIdToSessionId")
	procCreateJobObjectW        = kernel32.NewProc("CreateJobObjectW")
	procAssignProcessToJob      = kernel32.NewProc("AssignProcessToJobObject")
	procTerminateJobObject      = kernel32.NewProc("TerminateJobObject")
	procResumeThread            = kernel32.NewProc("ResumeThread")
	wtsapi32                    = syscall.NewLazyDLL("wtsapi32.dll")
	procWTSQueryUserToken       = wtsapi32.NewProc("WTSQueryUserToken")
	userenv                     = syscall.NewLazyDLL("userenv.dll")
	procCreateEnvironmentBlock  = userenv.NewProc("CreateEnvironmentBlock")
	procDestroyEnvironmentBlock = userenv.NewProc("DestroyEnvironmentBlock")
	procGetUserProfileDirectory = userenv.NewProc("GetUserProfileDirectoryW")
)

const (
	logon32LogonInteractive  = 2
	logon32ProviderDefault   = 0
	logonWithProfile         = 1
	tokenElevationType       = 18
	tokenLinkedToken         = 19
	tokenElevationLimited    = 3
	createSuspended          = 0x00000004
	createUnicodeEnvironment = 0x00000400
	createNoWindow           = 0x08000000
	handleFlagInherit        = 1
	noSession                = 0xFFFFFFFF
)

var spawnMutex sync.Mutex

func prepareStub() {
	if file, err := os.Create(stubLogPath); err == nil {
		os.Stderr = file
	}
}

// execAgent runs the agent until it exits: Windows has no exec, so the stub stays as its parent,
// and fetches it again when it has gone.
func execAgent(path string) error {
	cmd := exec.Command(path, "serve")
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	return fmt.Errorf("the agent exited: %v", err)
}

func login(name string, argv []string) error {
	return errors.New("login is for macOS")
}

// start runs spec as its user: a command line in PowerShell, as Windows' sshd has it with Hobo's
// DefaultShell, or this binary's put or get. Elevated, as an SSH login of an administrator is.
// Outside the desktop session, a logon of the user's own, started by CreateProcessWithTokenW,
// whose secondary logon service gives it session 0's desktop and loads its profile. In the
// desktop session (`exec --gui`), the console user's token, with CreateProcessAsUser:
// CreateProcessWithTokenW puts the process in session 0 whatever the token's session (checked
// 2026-11-08 on 11 build 26300).
func start(spec commandSpec) (process, error) {
	// Until the child has its handles: CreateProcessAsUser hands it every inheritable one.
	spawnMutex.Lock()
	defer spawnMutex.Unlock()
	var token syscall.Token
	var err error
	if spec.desktop {
		token, err = desktopToken()
	} else {
		token, err = logonToken(spec.user)
	}
	if err != nil {
		return nil, err
	}
	defer token.Close()

	var commandLine string
	if spec.self != nil {
		words := []string{syscall.EscapeArg(selfPath())}
		for _, arg := range spec.self {
			words = append(words, syscall.EscapeArg(arg))
		}
		commandLine = strings.Join(words, " ")
	} else {
		// The output's encoding as exec.ps1 sets it, for output that isn't ASCII.
		line := "[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); " + spec.line
		commandLine = `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -c ` + syscall.EscapeArg(line)
	}

	proc := &windowsProcess{}
	var childEnds []syscall.Handle
	defer func() {
		for _, h := range childEnds {
			syscall.CloseHandle(h)
		}
	}()
	inheritable := &syscall.SecurityAttributes{InheritHandle: 1}
	inheritable.Length = uint32(unsafe.Sizeof(*inheritable))

	var stdin syscall.Handle
	if spec.stdin {
		var write syscall.Handle
		if err := syscall.CreatePipe(&stdin, &write, inheritable, 0); err != nil {
			return nil, err
		}
		syscall.SetHandleInformation(write, handleFlagInherit, 0)
		proc.stdin = os.NewFile(uintptr(write), "stdin")
	} else {
		nul, _ := syscall.UTF16PtrFromString("NUL")
		if stdin, err = syscall.CreateFile(nul, syscall.GENERIC_READ, syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, inheritable, syscall.OPEN_EXISTING, 0, 0); err != nil {
			return nil, err
		}
	}
	childEnds = append(childEnds, stdin)
	outputs := []io.Writer{spec.stdout, spec.stderr}
	var writeEnds [2]syscall.Handle
	for i, output := range outputs {
		var read syscall.Handle
		if err := syscall.CreatePipe(&read, &writeEnds[i], inheritable, 0); err != nil {
			proc.closeStdin()
			return nil, err
		}
		syscall.SetHandleInformation(read, handleFlagInherit, 0)
		childEnds = append(childEnds, writeEnds[i])
		proc.output = append(proc.output, &gate{w: output})
		proc.reads = append(proc.reads, os.NewFile(uintptr(read), "output"))
	}

	environment, err := environmentBlock(token)
	if err != nil {
		proc.closeAll()
		return nil, err
	}
	defer procDestroyEnvironmentBlock.Call(uintptr(unsafe.Pointer(environment)))
	home, err := profileDirectory(token)
	if err != nil {
		proc.closeAll()
		return nil, err
	}

	var si syscall.StartupInfo
	si.Cb = uint32(unsafe.Sizeof(si))
	si.Flags = syscall.STARTF_USESTDHANDLES
	si.StdInput = stdin
	si.StdOutput = writeEnds[0]
	si.StdErr = writeEnds[1]
	// Named, not inherited: the logon has no access to this SYSTEM task's window station, and
	// commands started there die with STATUS_DLL_INIT_FAILED.
	si.Desktop, _ = syscall.UTF16PtrFromString(`winsta0\default`)
	// Suspended until it is in its job, so that nothing it starts can get away from a cancel; no
	// console window, which would show on the desktop (and in screenshots).
	flags := uint32(createSuspended | createUnicodeEnvironment | createNoWindow)
	commandLinePtr, err := syscall.UTF16PtrFromString(commandLine)
	if err != nil {
		proc.closeAll()
		return nil, err
	}
	homePtr, _ := syscall.UTF16PtrFromString(home)
	var pi syscall.ProcessInformation
	var callErr error
	if spec.desktop {
		// Inheriting every inheritable handle, which spawnMutex keeps to this command's own.
		callErr = syscall.CreateProcessAsUser(token, nil, commandLinePtr, nil, nil, true, flags, environment, homePtr, &si, &pi)
	} else if r, _, err := procCreateProcessWithTokenW.Call(uintptr(token), logonWithProfile, 0, uintptr(unsafe.Pointer(commandLinePtr)),
		uintptr(flags), uintptr(unsafe.Pointer(environment)), uintptr(unsafe.Pointer(homePtr)), uintptr(unsafe.Pointer(&si)), uintptr(unsafe.Pointer(&pi))); r == 0 {
		callErr = err
	}
	if callErr != nil {
		proc.closeAll()
		return nil, fmt.Errorf("starting %s: %w", commandLine, callErr)
	}
	defer syscall.CloseHandle(pi.Thread)
	proc.process = pi.Process
	job, _, jobErr := procCreateJobObjectW.Call(0, 0)
	if job == 0 {
		syscall.TerminateProcess(pi.Process, 1)
		proc.closeAll()
		return nil, fmt.Errorf("creating a job object: %w", jobErr)
	}
	proc.job = syscall.Handle(job)
	if r, _, err := procAssignProcessToJob.Call(job, uintptr(pi.Process)); r == 0 {
		syscall.TerminateProcess(pi.Process, 1)
		proc.closeAll()
		return nil, fmt.Errorf("putting the command in its job: %w", err)
	}
	procResumeThread.Call(uintptr(pi.Thread))
	for i := range proc.reads {
		proc.copies.Add(1)
		go func(read *os.File, output io.Writer) {
			defer proc.copies.Done()
			_, _ = io.Copy(output, read)
			read.Close()
		}(proc.reads[i], proc.output[i])
	}
	return proc, nil
}

// logonToken logs the user on with the convention's password.
func logonToken(name string) (syscall.Token, error) {
	user, _ := syscall.UTF16PtrFromString(name)
	domain, _ := syscall.UTF16PtrFromString(".")
	password, _ := syscall.UTF16PtrFromString(windowsPassword)
	var token syscall.Token
	r, _, err := procLogonUserW.Call(uintptr(unsafe.Pointer(user)), uintptr(unsafe.Pointer(domain)), uintptr(unsafe.Pointer(password)),
		logon32LogonInteractive, logon32ProviderDefault, uintptr(unsafe.Pointer(&token)))
	if r == 0 {
		return 0, fmt.Errorf("logging %s on: %w", name, err)
	}
	return elevated(token)
}

// desktopToken is the console session's user, once their desktop is up: Explorer running there.
func desktopToken() (syscall.Token, error) {
	deadline := time.Now().Add(desktopWaitSeconds * time.Second)
	for {
		session, _, _ := procActiveConsoleSession.Call()
		if session != noSession && explorerRunsIn(uint32(session)) {
			var token syscall.Token
			if r, _, _ := procWTSQueryUserToken.Call(session, uintptr(unsafe.Pointer(&token))); r != 0 {
				return elevated(token)
			}
		}
		if time.Now().After(deadline) {
			return 0, exitEarly{desktopUnavailableStatus, fmt.Sprintf("vagrant's desktop session isn't up after %d seconds", desktopWaitSeconds)}
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func explorerRunsIn(session uint32) bool {
	snapshot, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(snapshot)
	var entry syscall.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	for err = syscall.Process32First(snapshot, &entry); err == nil; err = syscall.Process32Next(snapshot, &entry) {
		if !strings.EqualFold(syscall.UTF16ToString(entry.ExeFile[:]), "explorer.exe") {
			continue
		}
		var id uint32
		if r, _, _ := procProcessIdToSessionId.Call(uintptr(entry.ProcessID), uintptr(unsafe.Pointer(&id))); r != 0 && id == session {
			return true
		}
	}
	return false
}

// elevated is token's full counterpart, if UAC gave it a filtered one. Asked as SYSTEM, the linked
// token is a primary one, which a process can be started with.
func elevated(token syscall.Token) (syscall.Token, error) {
	var kind, returned uint32
	if err := syscall.GetTokenInformation(token, tokenElevationType, (*byte)(unsafe.Pointer(&kind)), 4, &returned); err != nil || kind != tokenElevationLimited {
		return token, nil
	}
	var linked syscall.Token
	if err := syscall.GetTokenInformation(token, tokenLinkedToken, (*byte)(unsafe.Pointer(&linked)), uint32(unsafe.Sizeof(linked)), &returned); err != nil {
		token.Close()
		return 0, fmt.Errorf("getting the elevated token: %w", err)
	}
	token.Close()
	return linked, nil
}

func environmentBlock(token syscall.Token) (*uint16, error) {
	var block *uint16
	if r, _, err := procCreateEnvironmentBlock.Call(uintptr(unsafe.Pointer(&block)), uintptr(token), 0); r == 0 {
		return nil, fmt.Errorf("building the user's environment: %w", err)
	}
	return block, nil
}

func profileDirectory(token syscall.Token) (string, error) {
	buffer := make([]uint16, syscall.MAX_PATH)
	size := uint32(len(buffer))
	if r, _, err := procGetUserProfileDirectory.Call(uintptr(token), uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size))); r == 0 {
		return "", fmt.Errorf("finding the user's profile: %w", err)
	}
	return syscall.UTF16ToString(buffer), nil
}

type windowsProcess struct {
	process syscall.Handle
	job     syscall.Handle
	stdin   *os.File
	reads   []*os.File
	output  []*gate
	copies  sync.WaitGroup
	mutex   sync.Mutex
	done    bool
}

func (p *windowsProcess) Stdin() io.WriteCloser { return p.stdin }

// Wait waits for the command, then briefly for the end of its output: an app it left running
// can hold the pipes open forever, and what that writes later is dropped.
func (p *windowsProcess) Wait() (int32, error) {
	if _, err := syscall.WaitForSingleObject(p.process, syscall.INFINITE); err != nil {
		return 0, err
	}
	var code uint32
	err := syscall.GetExitCodeProcess(p.process, &code)
	copied := make(chan struct{})
	go func() {
		p.copies.Wait()
		close(copied)
	}()
	select {
	case <-copied:
	case <-time.After(2 * time.Second):
	}
	for _, output := range p.output {
		output.close()
	}
	p.mutex.Lock()
	p.done = true
	syscall.CloseHandle(p.process)
	syscall.CloseHandle(p.job)
	p.mutex.Unlock()
	if err != nil {
		return 0, err
	}
	return int32(code), nil
}

// Terminate ends the command's job: it, and everything it started.
func (p *windowsProcess) Terminate() {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	if !p.done {
		procTerminateJobObject.Call(uintptr(p.job), 1)
	}
}

func (p *windowsProcess) closeStdin() {
	if p.stdin != nil {
		p.stdin.Close()
	}
}

func (p *windowsProcess) closeAll() {
	p.closeStdin()
	for _, read := range p.reads {
		read.Close()
	}
}

// gate passes writes on until it is closed, and then drops them.
type gate struct {
	mutex  sync.Mutex
	w      io.Writer
	closed bool
}

func (g *gate) Write(b []byte) (int, error) {
	g.mutex.Lock()
	defer g.mutex.Unlock()
	if g.closed {
		return len(b), nil
	}
	return g.w.Write(b)
}

func (g *gate) close() {
	g.mutex.Lock()
	g.closed = true
	g.mutex.Unlock()
}

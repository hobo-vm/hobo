package main

import (
	"fmt"
	"io"
	"sync"
	"syscall"
	"unsafe"
)

// AF_VSOCK through virtio-win's viosock: its driver, and the Winsock provider its service
// registers, which takes sockets of an address family the driver hands out (vio_sockets.h's
// ViosockGetAF). The syscall package can't bind or connect a sockaddr it doesn't know, so the
// socket calls are ws2_32's own.

var (
	ws2         = syscall.NewLazyDLL("ws2_32.dll")
	procBind    = ws2.NewProc("bind")
	procListen  = ws2.NewProc("listen")
	procAccept  = ws2.NewProc("accept")
	procConnect = ws2.NewProc("connect")
	procRecv    = ws2.NewProc("recv")
	procSend    = ws2.NewProc("send")
)

const (
	viosockDevice = `\??\Viosock`
	ioctlGetAF    = 0x0801300C
	// SOCKET_ERROR, from the calls that return an int: a 32-bit -1, whatever the register's upper half.
	socketError   = -1
	invalidSocket = ^uintptr(0)
	cidAny        = 0xFFFFFFFF
)

// struct sockaddr_vm, as viosock has it: no flags or padding after the CID.
type sockaddrVM struct {
	family    uint16
	reserved1 uint16
	port      uint32
	cid       uint32
}

var (
	winsock     sync.Once
	winsockErr  error
	familyMutex sync.Mutex
	family      uint16
)

// vsockFamily asks the driver for its address family, which it may not have until it has loaded:
// a stub started at boot can get here first, and retries.
func vsockFamily() (uint16, error) {
	winsock.Do(func() {
		var data syscall.WSAData
		winsockErr = syscall.WSAStartup(0x0202, &data)
	})
	if winsockErr != nil {
		return 0, fmt.Errorf("WSAStartup: %w", winsockErr)
	}
	familyMutex.Lock()
	defer familyMutex.Unlock()
	if family != 0 {
		return family, nil
	}
	name, _ := syscall.UTF16PtrFromString(viosockDevice)
	device, err := syscall.CreateFile(name, syscall.GENERIC_READ, syscall.FILE_SHARE_READ, nil, syscall.OPEN_EXISTING, syscall.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return 0, fmt.Errorf("opening viosock's device: %w", err)
	}
	defer syscall.CloseHandle(device)
	var af, returned uint32
	if err := syscall.DeviceIoControl(device, ioctlGetAF, nil, 0, (*byte)(unsafe.Pointer(&af)), 4, &returned, nil); err != nil {
		return 0, fmt.Errorf("asking viosock for its address family: %w", err)
	}
	family = uint16(af)
	return family, nil
}

func vsockSocket() (syscall.Handle, uint16, error) {
	af, err := vsockFamily()
	if err != nil {
		return syscall.InvalidHandle, 0, err
	}
	s, err := syscall.Socket(int(af), syscall.SOCK_STREAM, 0)
	if err != nil {
		return syscall.InvalidHandle, 0, fmt.Errorf("vsock socket: %w", err)
	}
	return s, af, nil
}

// vsockListen listens on port for connections from any CID; accept filters them.
func vsockListen(port uint32) (syscall.Handle, error) {
	s, af, err := vsockSocket()
	if err != nil {
		return syscall.InvalidHandle, err
	}
	addr := sockaddrVM{family: af, port: port, cid: cidAny}
	if r, _, err := procBind.Call(uintptr(s), uintptr(unsafe.Pointer(&addr)), unsafe.Sizeof(addr)); int32(r) == socketError {
		syscall.Closesocket(s)
		return syscall.InvalidHandle, fmt.Errorf("vsock bind to port %d: %w", port, err)
	}
	if r, _, err := procListen.Call(uintptr(s), 16); int32(r) == socketError {
		syscall.Closesocket(s)
		return syscall.InvalidHandle, fmt.Errorf("vsock listen: %w", err)
	}
	return s, nil
}

// vsockAccept waits for a connection and returns it with the peer's CID.
func vsockAccept(listener syscall.Handle) (io.ReadWriteCloser, uint32, error) {
	var addr sockaddrVM
	size := int32(unsafe.Sizeof(addr))
	r, _, err := procAccept.Call(uintptr(listener), uintptr(unsafe.Pointer(&addr)), uintptr(unsafe.Pointer(&size)))
	if r == invalidSocket {
		return nil, 0, fmt.Errorf("vsock accept: %w", err)
	}
	return &vsockConn{s: syscall.Handle(r)}, addr.cid, nil
}

// vsockDial connects to port on the host.
func vsockDial(port uint32) (io.ReadWriteCloser, error) {
	s, af, err := vsockSocket()
	if err != nil {
		return nil, err
	}
	addr := sockaddrVM{family: af, port: port, cid: hostCID}
	if r, _, err := procConnect.Call(uintptr(s), uintptr(unsafe.Pointer(&addr)), unsafe.Sizeof(addr)); int32(r) == socketError {
		syscall.Closesocket(s)
		return nil, fmt.Errorf("vsock connect to the host's port %d: %w", port, err)
	}
	return &vsockConn{s: s}, nil
}

// vsockConn is a connected socket, read and written with blocking recv and send: viosock's
// provider isn't one whose sockets ReadFile and WriteFile take.
type vsockConn struct {
	s         syscall.Handle
	closeOnce sync.Once
}

func (c *vsockConn) Read(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	if len(b) > 1<<30 {
		b = b[:1<<30]
	}
	r, _, err := procRecv.Call(uintptr(c.s), uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)), 0)
	n := int32(r)
	if n == socketError {
		return 0, fmt.Errorf("vsock recv: %w", err)
	}
	if n == 0 {
		return 0, io.EOF
	}
	return int(n), nil
}

func (c *vsockConn) Write(b []byte) (int, error) {
	written := 0
	for written < len(b) {
		chunk := b[written:]
		if len(chunk) > 1<<30 {
			chunk = chunk[:1<<30]
		}
		r, _, err := procSend.Call(uintptr(c.s), uintptr(unsafe.Pointer(&chunk[0])), uintptr(len(chunk)), 0)
		n := int32(r)
		if n == socketError {
			return written, fmt.Errorf("vsock send: %w", err)
		}
		written += int(n)
	}
	return written, nil
}

func (c *vsockConn) Close() error {
	var err error
	c.closeOnce.Do(func() { err = syscall.Closesocket(c.s) })
	return err
}

package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// AF_VSOCK through raw system calls: the syscall package has no sockaddr for it, and the agent
// takes no dependencies (the build runs in SwiftPM's sandbox, without network access).

// The most a frame carries on its way out: a whole frame, except on macOS (vsock_darwin.go).
const maxWrite = maxFrame

const afVsock = 40

// struct sockaddr_vm.
type sockaddrVM struct {
	family    uint16
	reserved1 uint16
	port      uint32
	cid       uint32
	flags     uint8
	zero      [3]uint8
}

const cidAny = 0xFFFFFFFF

func vsockSocket() (int, error) {
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, fmt.Errorf("vsock socket: %w", err)
	}
	return fd, nil
}

// vsockListen listens on port for connections from any CID; accept filters them.
func vsockListen(port uint32) (int, error) {
	fd, err := vsockSocket()
	if err != nil {
		return -1, err
	}
	addr := sockaddrVM{family: afVsock, port: port, cid: cidAny}
	if _, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&addr)), unsafe.Sizeof(addr)); errno != 0 {
		syscall.Close(fd)
		return -1, fmt.Errorf("vsock bind to port %d: %w", port, errno)
	}
	if err := syscall.Listen(fd, 16); err != nil {
		syscall.Close(fd)
		return -1, fmt.Errorf("vsock listen: %w", err)
	}
	return fd, nil
}

// vsockAccept waits for a connection and returns it with the peer's CID.
func vsockAccept(listener int) (*os.File, uint32, error) {
	for {
		var addr sockaddrVM
		size := uint32(unsafe.Sizeof(addr))
		nfd, _, errno := syscall.Syscall6(syscall.SYS_ACCEPT4, uintptr(listener), uintptr(unsafe.Pointer(&addr)),
			uintptr(unsafe.Pointer(&size)), syscall.SOCK_CLOEXEC, 0, 0)
		if errno == syscall.EINTR || errno == syscall.ECONNABORTED {
			continue
		}
		if errno != 0 {
			return nil, 0, fmt.Errorf("vsock accept: %w", errno)
		}
		return os.NewFile(nfd, "vsock"), addr.cid, nil
	}
}

// vsockDial connects to port on the host.
func vsockDial(port uint32) (*os.File, error) {
	fd, err := vsockSocket()
	if err != nil {
		return nil, err
	}
	addr := sockaddrVM{family: afVsock, port: port, cid: hostCID}
	if _, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&addr)), unsafe.Sizeof(addr)); errno != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("vsock connect to the host's port %d: %w", port, errno)
	}
	return os.NewFile(uintptr(fd), "vsock"), nil
}

package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// AF_VSOCK through raw system calls, as on Linux; macOS's sockaddr_vm (<sys/vsock.h>) has a
// length byte and no flags.

const afVsock = 40

type sockaddrVM struct {
	length    uint8
	family    uint8
	reserved1 uint16
	port      uint32
	cid       uint32
}

const cidAny = 0xFFFFFFFF

func vsockSocket() (int, error) {
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM, 0)
	if err != nil {
		return -1, fmt.Errorf("vsock socket: %w", err)
	}
	syscall.CloseOnExec(fd)
	return fd, nil
}

func newAddress(port, cid uint32) sockaddrVM {
	return sockaddrVM{length: uint8(unsafe.Sizeof(sockaddrVM{})), family: afVsock, port: port, cid: cid}
}

// vsockListen listens on port for connections from any CID; accept filters them.
func vsockListen(port uint32) (int, error) {
	fd, err := vsockSocket()
	if err != nil {
		return -1, err
	}
	addr := newAddress(port, cidAny)
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
		nfd, _, errno := syscall.Syscall(syscall.SYS_ACCEPT, uintptr(listener), uintptr(unsafe.Pointer(&addr)), uintptr(unsafe.Pointer(&size)))
		if errno == syscall.EINTR || errno == syscall.ECONNABORTED {
			continue
		}
		if errno != 0 {
			return nil, 0, fmt.Errorf("vsock accept: %w", errno)
		}
		syscall.CloseOnExec(int(nfd))
		return os.NewFile(nfd, "vsock"), addr.cid, nil
	}
}

// vsockDial connects to port on the host.
func vsockDial(port uint32) (*os.File, error) {
	fd, err := vsockSocket()
	if err != nil {
		return nil, err
	}
	addr := newAddress(port, hostCID)
	if _, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&addr)), unsafe.Sizeof(addr)); errno != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("vsock connect to the host's port %d: %w", port, errno)
	}
	return os.NewFile(uintptr(fd), "vsock"), nil
}

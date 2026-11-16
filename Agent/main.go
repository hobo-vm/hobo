// hobo-agent is Hobo's guest agent (decision 15 in docs/design.md): the host's channel into a
// guest over virtio-vsock, in place of SSH. One binary, in three roles:
//
//	hobo-agent stub      installed in the guest at create; fetches the agent from the host and execs it
//	hobo-agent serve     the fetched agent: answers the host's requests on agentPort
//	hobo-agent put|get   one side of a copy, started by serve as the copy's user
//	hobo-agent rm        removes guest paths (`hobo rm`), started by serve as the request's user
//	hobo-agent clipboard the guest's side of the shared clipboard, started by serve in the desktop session
//	hobo-agent login     becomes a user and execs a command, where serve can't start it as them
//	hobo-agent gnome-extension  installs hobo's GNOME Shell extension, from a Linux desktop's recipe step
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: hobo-agent stub|serve")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "stub":
		runStub()
	case "serve":
		serve()
	case "put":
		if len(os.Args) != 5 {
			os.Exit(2)
		}
		finish(putTar(os.Stdin, os.Args[2], os.Args[3] == "1", os.Args[4] == "1"))
	case "get":
		if len(os.Args) < 3 {
			os.Exit(2)
		}
		finish(getTar(os.Stdout, os.Stderr, os.Args[2:]))
	case "rm":
		if len(os.Args) < 4 {
			os.Exit(2)
		}
		home, err := os.Getwd()
		if err != nil {
			fmt.Fprintf(os.Stderr, "hobo-agent rm: %v\n", err)
			os.Exit(1)
		}
		finish(removePaths(os.Stderr, home, os.Args[3:], os.Args[2] == "1"))
	case "clipboard":
		board, err := newGuestClipboard()
		if err == nil {
			err = runClipboard(board, os.Stdin, os.Stdout, clipboardPoll)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "hobo-agent clipboard: %v\n", err)
			os.Exit(1)
		}
	case "gnome-extension":
		if err := installGnomeExtension(); err != nil {
			fmt.Fprintf(os.Stderr, "hobo-agent: %v\n", err)
			os.Exit(1)
		}
	case "login":
		if len(os.Args) < 4 {
			os.Exit(2)
		}
		err := login(os.Args[2], os.Args[3:])
		fmt.Fprintf(os.Stderr, "hobo-agent: %v\n", err)
		os.Exit(126)
	default:
		fmt.Fprintf(os.Stderr, "hobo-agent: unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}

func finish(err error) {
	if err == nil {
		os.Exit(0)
	}
	if err != errReported {
		fmt.Fprintln(os.Stderr, err)
	}
	os.Exit(1)
}

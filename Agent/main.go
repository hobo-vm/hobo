// hobo-agent is Hobo's guest agent (decision 15 in docs/design.md): the host's channel into a
// guest over virtio-vsock, in place of SSH. One binary, in three roles:
//
//	hobo-agent stub      installed in the guest at create; fetches the agent from the host and execs it
//	hobo-agent serve     the fetched agent: answers the host's requests on agentPort
//	hobo-agent put|get   one side of a copy, started by serve as the copy's user
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
		if len(os.Args) != 4 {
			os.Exit(2)
		}
		finishCopy(putTar(os.Stdin, os.Args[2], os.Args[3] == "1"))
	case "get":
		if len(os.Args) < 3 {
			os.Exit(2)
		}
		finishCopy(getTar(os.Stdout, os.Stderr, os.Args[3:], os.Args[2] == "1"))
	default:
		fmt.Fprintf(os.Stderr, "hobo-agent: unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}

func finishCopy(err error) {
	if err == nil {
		os.Exit(0)
	}
	if err != errCopyFailed {
		fmt.Fprintln(os.Stderr, err)
	}
	os.Exit(1)
}

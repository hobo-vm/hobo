package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

// The stub is what create installs in the guest, run at boot as root by the guest's service
// manager. It fetches the agent from the host it is running under and execs it, so the agent
// always matches the hobo serving it, however old the guest is.
//
// FROZEN: this exchange can never change, since a stub installed today has to work with every
// later hobo. The stub sends one JSON line, {"fetch":"<GOOS>-<GOARCH>"}, to the host's fetchPort;
// the host answers with one JSON line, {"size":<bytes>} or {"error":"<reason>"}, and then that
// many bytes of executable. Anything new belongs in the agent, which the host can change freely.

type fetchRequest struct {
	Fetch string `json:"fetch"`
}

type fetchResponse struct {
	Size  int64  `json:"size"`
	Error string `json:"error"`
}

func runStub() {
	prepareStub()
	for attempt := 0; ; attempt++ {
		path, err := fetchAgent()
		if err == nil {
			err = execAgent(path)
		}
		// The host listens from before the guest boots, so a failure is worth a line in the
		// guest's log, but not one a second for as long as the host isn't there.
		if attempt < 5 || attempt%60 == 0 {
			fmt.Fprintf(os.Stderr, "hobo-agent stub: %v; retrying\n", err)
		}
		time.Sleep(time.Second)
	}
}

func fetchAgent() (string, error) {
	conn, err := vsockDial(fetchPort)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	line, err := json.Marshal(fetchRequest{Fetch: runtime.GOOS + "-" + runtime.GOARCH})
	if err != nil {
		return "", err
	}
	if _, err := conn.Write(append(line, '\n')); err != nil {
		return "", fmt.Errorf("sending the fetch: %w", err)
	}
	reader := bufio.NewReader(conn)
	answer, err := reader.ReadBytes('\n')
	if err != nil {
		return "", fmt.Errorf("reading the host's answer: %w", err)
	}
	var response fetchResponse
	if err := json.Unmarshal(answer, &response); err != nil {
		return "", fmt.Errorf("the host's answer isn't JSON: %w", err)
	}
	if response.Error != "" {
		return "", fmt.Errorf("the host refused the fetch: %s", response.Error)
	}
	if err := os.MkdirAll(agentRunDirectory, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(agentRunDirectory, agentExecutableName)
	partial := path + ".partial"
	file, err := os.OpenFile(partial, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return "", err
	}
	_, copyErr := io.CopyN(file, reader, response.Size)
	closeErr := file.Close()
	if copyErr != nil {
		return "", fmt.Errorf("receiving the agent: %w", copyErr)
	}
	if closeErr != nil {
		return "", closeErr
	}
	return path, os.Rename(partial, path)
}

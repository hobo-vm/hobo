package main

import "fmt"

// Windows guests have no tools yet (tool.go).
func ensureTool(name, user string) error {
	return fmt.Errorf("unknown tool %q", name)
}

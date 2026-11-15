package main

import (
	"bytes"
	"embed"
	"fmt"
	"os"
	"path/filepath"
)

// hobo's GNOME Shell extension, which hobo ui's Linux backend asks where windows are
// (gnome-extension/extension.js). The desktop recipe step installs it with `hobo-agent
// gnome-extension`, before the desktop's first login; each boot's agent puts its own copy in place
// too, for the next login, so it follows hobo's updates.
//
//go:embed gnome-extension
var gnomeExtension embed.FS

const gnomeExtensionDirectory = "/usr/share/gnome-shell/extensions/hobo@gsquared.app"

// installGnomeExtension writes the extension where GNOME Shell finds system extensions, if this
// guest has GNOME Shell, leaving files that already match alone.
func installGnomeExtension() error {
	if _, err := os.Stat("/usr/share/gnome-shell"); err != nil {
		return nil
	}
	entries, err := gnomeExtension.ReadDir("gnome-extension")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(gnomeExtensionDirectory, 0o755); err != nil {
		return err
	}
	for _, entry := range entries {
		data, err := gnomeExtension.ReadFile("gnome-extension/" + entry.Name())
		if err != nil {
			return err
		}
		path := filepath.Join(gnomeExtensionDirectory, entry.Name())
		if existing, err := os.ReadFile(path); err == nil && bytes.Equal(existing, data) {
			continue
		}
		if err := os.WriteFile(path, data, 0o644); err != nil {
			return fmt.Errorf("installing hobo's GNOME Shell extension: %w", err)
		}
	}
	return nil
}

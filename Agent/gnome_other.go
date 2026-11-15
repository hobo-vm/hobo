//go:build !linux

package main

// Only Linux guests run GNOME Shell.
func installGnomeExtension() error { return nil }

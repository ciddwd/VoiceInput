// Package focus reports the user's currently focused application so the
// mobile client can auto-switch its snippet category (VSCode → 编程类, etc).
package focus

// Info describes the current foreground application. ProcessName is the
// short binary name without path/extension (e.g. "Code.exe", "chrome.exe"),
// which is what we match against category regexes.
type Info struct {
	AppName     string // window title or display name
	ProcessName string
}

// Detector is the per-platform implementation. Returns zero Info when nothing
// useful can be determined (e.g. screen locked, Wayland without elevation).
type Detector interface {
	Current() Info
	Close() error
}

// New returns the platform-appropriate Detector.
func New() Detector { return newPlatform() }

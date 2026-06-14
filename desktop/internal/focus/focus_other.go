//go:build !windows

package focus

// Stub for macOS / Linux. The production implementations:
//   macOS:  NSWorkspace.shared.frontmostApplication.localizedName / bundleIdentifier
//   Linux:  Xlib _NET_ACTIVE_WINDOW (X11) or wlr-foreign-toplevel-management (Wayland)

type stubDetector struct{}

func newPlatform() Detector { return &stubDetector{} }

func (stubDetector) Current() Info { return Info{} }
func (stubDetector) Close() error  { return nil }

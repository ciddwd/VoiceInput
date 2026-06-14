//go:build linux

package inject

// Linux implementation is a stub for now. X11 path will use XTestFakeKeyEvent;
// Wayland fallback will use wtype or ydotool when present. Clipboard save/
// restore via xclip or wl-clipboard. Tracked under stage-2 of the rollout plan.

type linuxInjector struct{}

func newPlatform() Injector { return &linuxInjector{} }

func (l *linuxInjector) Type(string) error              { return ErrUnsupportedPlatform }
func (l *linuxInjector) Paste(string) error             { return ErrUnsupportedPlatform }
func (l *linuxInjector) Inject(string, Mode, int) error { return ErrUnsupportedPlatform }
func (l *linuxInjector) Clear() error                   { return ErrUnsupportedPlatform }
func (l *linuxInjector) PressKey(string) error          { return ErrUnsupportedPlatform }

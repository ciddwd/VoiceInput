//go:build darwin

package inject

// macOS implementation is a stub for now. The production path will use
// CGEventCreateKeyboardEvent + CGEventKeyboardSetUnicodeString for Type,
// NSPasteboard for clipboard save/restore, and Cmd+V via CGEventPost for Paste.
// Tracked under stage-2 of the rollout plan.

type macInjector struct{}

func newPlatform() Injector { return &macInjector{} }

func (m *macInjector) Type(string) error              { return ErrUnsupportedPlatform }
func (m *macInjector) Paste(string) error             { return ErrUnsupportedPlatform }
func (m *macInjector) Inject(string, Mode, int) error { return ErrUnsupportedPlatform }
func (m *macInjector) Clear() error                   { return ErrUnsupportedPlatform }
func (m *macInjector) PressKey(string) error          { return ErrUnsupportedPlatform }

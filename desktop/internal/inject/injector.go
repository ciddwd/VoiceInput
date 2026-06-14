// Package inject abstracts the per-platform machinery used to deliver text
// to whichever input field currently holds the OS focus.
//
// Three injection modes:
//
//   ModeType  - Per-character keyboard simulation via OS keyboard APIs. Best
//               fidelity, native IME behaviour, but slower for long text.
//   ModePaste - Stash the text on the clipboard, send Ctrl/Cmd+V, restore the
//               previous clipboard content. Fastest for long text; minor
//               clipboard side-effect during the ~200 ms restore window.
//   ModeAuto  - Pick Type for short runs, Paste for long ones, threshold-based.
//
// PressKey delivers a single virtual key (Enter / Tab / Space / Backspace) so
// the mobile client can request a suffix after each commit.
package inject

import "errors"

// ErrUnsupportedPlatform is returned by injector methods on platforms that do
// not yet have a real implementation (currently macOS and Linux are stubs).
var ErrUnsupportedPlatform = errors.New("text injection is not implemented for this platform yet")

type Mode int

const (
	ModeAuto Mode = iota
	ModeType
	ModePaste
)

// DefaultThreshold is the rune count above which ModeAuto switches to Paste.
const DefaultThreshold = 50

type Injector interface {
	// Type emits each rune in text as a Unicode key event so the active IME /
	// input field sees a normal keystroke stream.
	Type(text string) error

	// Paste copies text to the clipboard, sends Ctrl+V (Cmd+V on macOS), then
	// restores the previous clipboard contents.
	Paste(text string) error

	// Inject dispatches to Type or Paste according to mode. When mode is
	// ModeAuto, switches based on threshold.
	Inject(text string, mode Mode, threshold int) error

	// Clear selects-all and deletes in the focused field (Ctrl+A then Delete).
	Clear() error

	// PressKey emits a single named virtual key. Accepted names:
	// "enter", "tab", "space", "backspace".
	PressKey(name string) error
}

// New returns the platform-appropriate Injector. On unsupported platforms it
// still returns a non-nil Injector whose methods all yield ErrUnsupportedPlatform,
// so the rest of the app can run without compile-time platform branching.
func New() Injector { return newPlatform() }

// ParseMode converts the wire-protocol string into a Mode.
func ParseMode(s string) Mode {
	switch s {
	case "type":
		return ModeType
	case "paste":
		return ModePaste
	default:
		return ModeAuto
	}
}

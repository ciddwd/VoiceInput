//go:build windows

package inject

import (
	"fmt"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var (
	modUser32     = syscall.NewLazyDLL("user32.dll")
	procSendInput = modUser32.NewProc("SendInput")
)

const (
	inputKeyboard    = 1
	keyeventfKeyup   = 0x0002
	keyeventfUnicode = 0x0004

	vkBack    = 0x08
	vkTab     = 0x09
	vkReturn  = 0x0D
	vkSpace   = 0x20
	vkA       = 0x41
	vkV       = 0x56
	vkDelete  = 0x2E
	vkShift   = 0x10
	vkControl = 0x11
	vkAlt     = 0x12 // VK_MENU
	vkLWin    = 0x5B
	vkEscape  = 0x1B
	vkUp      = 0x26
	vkDown    = 0x28
	vkLeft    = 0x25
	vkRight   = 0x27
)

// winInput is the 64-bit layout of the Win32 INPUT struct for KEYBDINPUT.
// Total size 40 bytes: type(4) + pad(4) + KEYBDINPUT(24) + trailing pad(8).
// The trailing pad makes the union size match MOUSEINPUT, as Windows expects.
type winInput struct {
	inputType   uint32
	_           uint32
	wVk         uint16
	wScan       uint16
	dwFlags     uint32
	time        uint32
	_           uint32
	dwExtraInfo uintptr
	_           [8]byte
}

func sendInputs(inputs []winInput) error {
	if len(inputs) == 0 {
		return nil
	}
	ret, _, err := procSendInput.Call(
		uintptr(len(inputs)),
		uintptr(unsafe.Pointer(&inputs[0])),
		unsafe.Sizeof(winInput{}),
	)
	if int(ret) != len(inputs) {
		return fmt.Errorf("SendInput sent %d/%d events: %v", ret, len(inputs), err)
	}
	return nil
}

func unicodeKey(unit uint16, up bool) winInput {
	flags := uint32(keyeventfUnicode)
	if up {
		flags |= keyeventfKeyup
	}
	return winInput{inputType: inputKeyboard, wScan: unit, dwFlags: flags}
}

func vkKey(vk uint16, up bool) winInput {
	flags := uint32(0)
	if up {
		flags = keyeventfKeyup
	}
	return winInput{inputType: inputKeyboard, wVk: vk, dwFlags: flags}
}

type winInjector struct{}

func newPlatform() Injector { return &winInjector{} }

func (w *winInjector) Type(text string) error {
	units := utf16.Encode([]rune(text))
	inputs := make([]winInput, 0, len(units)*2)
	for _, u := range units {
		inputs = append(inputs, unicodeKey(u, false), unicodeKey(u, true))
	}
	// SendInput accepts up to ~5000 events at once. Chunk to stay well under
	// that, and so long inputs don't monopolise the input thread.
	const chunk = 200
	for i := 0; i < len(inputs); i += chunk {
		end := i + chunk
		if end > len(inputs) {
			end = len(inputs)
		}
		if err := sendInputs(inputs[i:end]); err != nil {
			return err
		}
	}
	return nil
}

func (w *winInjector) Paste(text string) error {
	saved, _ := saveClipboardText() // best-effort; missing prior content is fine
	if err := setClipboardText(text); err != nil {
		return fmt.Errorf("set clipboard: %w", err)
	}
	if err := sendInputs([]winInput{
		vkKey(vkControl, false),
		vkKey(vkV, false),
		vkKey(vkV, true),
		vkKey(vkControl, true),
	}); err != nil {
		return err
	}
	// Give the target app a moment to consume the paste before restoring,
	// otherwise the restored content can race in mid-paste.
	time.Sleep(200 * time.Millisecond)
	if saved != nil {
		_ = setClipboardText(*saved)
	}
	return nil
}

func (w *winInjector) Inject(text string, mode Mode, threshold int) error {
	if text == "" {
		return nil
	}
	switch mode {
	case ModeType:
		return w.Type(text)
	case ModePaste:
		return w.Paste(text)
	default:
		if threshold <= 0 {
			threshold = DefaultThreshold
		}
		if len([]rune(text)) <= threshold {
			return w.Type(text)
		}
		return w.Paste(text)
	}
}

func (w *winInjector) Clear() error {
	if err := sendInputs([]winInput{
		vkKey(vkControl, false),
		vkKey(vkA, false),
		vkKey(vkA, true),
		vkKey(vkControl, true),
	}); err != nil {
		return err
	}
	return sendInputs([]winInput{
		vkKey(vkDelete, false),
		vkKey(vkDelete, true),
	})
}

func (w *winInjector) PressKey(spec string) error {
	// Accept either a bare key name ("enter") or a chord ("ctrl+enter",
	// "alt+shift+enter", …). The last segment is the main key; preceding
	// segments are modifiers held down while the key fires.
	parts := strings.Split(strings.ToLower(strings.TrimSpace(spec)), "+")
	if len(parts) == 0 || parts[0] == "" {
		return nil
	}
	mainName := strings.TrimSpace(parts[len(parts)-1])
	mainVK, err := keyNameToVK(mainName)
	if err != nil {
		return err
	}
	var mods []uint16
	for _, m := range parts[:len(parts)-1] {
		v, err := modifierToVK(strings.TrimSpace(m))
		if err != nil {
			return err
		}
		mods = append(mods, v)
	}

	inputs := make([]winInput, 0, (len(mods)+1)*2)
	for _, m := range mods {
		inputs = append(inputs, vkKey(m, false))
	}
	inputs = append(inputs, vkKey(mainVK, false), vkKey(mainVK, true))
	for i := len(mods) - 1; i >= 0; i-- {
		inputs = append(inputs, vkKey(mods[i], true))
	}
	return sendInputs(inputs)
}

func keyNameToVK(name string) (uint16, error) {
	switch name {
	case "enter", "return":
		return vkReturn, nil
	case "tab":
		return vkTab, nil
	case "space":
		return vkSpace, nil
	case "backspace", "back":
		return vkBack, nil
	case "delete", "del":
		return vkDelete, nil
	case "escape", "esc":
		return vkEscape, nil
	case "up":
		return vkUp, nil
	case "down":
		return vkDown, nil
	case "left":
		return vkLeft, nil
	case "right":
		return vkRight, nil
	}
	// Single letters a-z map to VK_A..VK_Z.
	if len(name) == 1 && name[0] >= 'a' && name[0] <= 'z' {
		return uint16(name[0] - 'a' + 0x41), nil
	}
	return 0, fmt.Errorf("unsupported key name: %q", name)
}

func modifierToVK(name string) (uint16, error) {
	switch name {
	case "ctrl", "control":
		return vkControl, nil
	case "alt", "menu":
		return vkAlt, nil
	case "shift":
		return vkShift, nil
	case "win", "cmd", "super", "meta":
		return vkLWin, nil
	}
	return 0, fmt.Errorf("unsupported modifier: %q", name)
}

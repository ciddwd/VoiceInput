//go:build windows

package inject

import (
	"fmt"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var (
	modUser32Clip        = syscall.NewLazyDLL("user32.dll")
	procOpenClipboard    = modUser32Clip.NewProc("OpenClipboard")
	procCloseClipboard   = modUser32Clip.NewProc("CloseClipboard")
	procEmptyClipboard   = modUser32Clip.NewProc("EmptyClipboard")
	procGetClipboardData = modUser32Clip.NewProc("GetClipboardData")
	procSetClipboardData = modUser32Clip.NewProc("SetClipboardData")

	modKernel32      = syscall.NewLazyDLL("kernel32.dll")
	procGlobalAlloc  = modKernel32.NewProc("GlobalAlloc")
	procGlobalLock   = modKernel32.NewProc("GlobalLock")
	procGlobalUnlock = modKernel32.NewProc("GlobalUnlock")
)

const (
	cfUnicodeText = 13
	gmemMoveable  = 0x0002
)

// saveClipboardText returns the current CF_UNICODETEXT clipboard contents, or
// nil if the clipboard holds something else (image, files, custom format). In
// that case Paste will simply not restore — we cannot perfectly preserve every
// format without rewriting half of OLE, and text-only restore is the pragmatic
// default for a voice-input workflow.
func saveClipboardText() (*string, error) {
	if err := openClipboard(); err != nil {
		return nil, err
	}
	defer procCloseClipboard.Call()

	h, _, _ := procGetClipboardData.Call(cfUnicodeText)
	if h == 0 {
		return nil, nil
	}
	ptr, _, _ := procGlobalLock.Call(h)
	if ptr == 0 {
		return nil, fmt.Errorf("GlobalLock failed")
	}
	defer procGlobalUnlock.Call(h)

	// Reinterpret the uintptr's bits as unsafe.Pointer via a Go pointer chain.
	// This is necessary because the clipboard heap is outside the Go runtime,
	// so a direct unsafe.Pointer(uintptr) cast trips vet's unsafeptr check.
	base := *(*unsafe.Pointer)(unsafe.Pointer(&ptr))
	var units []uint16
	for off := uintptr(0); ; off += 2 {
		u := *(*uint16)(unsafe.Add(base, off))
		if u == 0 {
			break
		}
		units = append(units, u)
	}
	s := string(utf16.Decode(units))
	return &s, nil
}

func setClipboardText(text string) error {
	if err := openClipboard(); err != nil {
		return err
	}
	defer procCloseClipboard.Call()

	procEmptyClipboard.Call()

	units := utf16.Encode([]rune(text))
	units = append(units, 0) // null terminator

	h, _, _ := procGlobalAlloc.Call(gmemMoveable, uintptr(len(units)*2))
	if h == 0 {
		return fmt.Errorf("GlobalAlloc failed")
	}
	ptr, _, _ := procGlobalLock.Call(h)
	if ptr == 0 {
		return fmt.Errorf("GlobalLock failed")
	}
	base := *(*unsafe.Pointer)(unsafe.Pointer(&ptr))
	for i, u := range units {
		*(*uint16)(unsafe.Add(base, uintptr(i*2))) = u
	}
	procGlobalUnlock.Call(h)

	ret, _, err := procSetClipboardData.Call(cfUnicodeText, h)
	if ret == 0 {
		return fmt.Errorf("SetClipboardData failed: %v", err)
	}
	return nil
}

// openClipboard retries on lock contention. The clipboard is a serially-shared
// resource: another app holding it for a few ms during Ctrl+C is normal.
func openClipboard() error {
	for i := 0; i < 20; i++ {
		ret, _, _ := procOpenClipboard.Call(0)
		if ret != 0 {
			return nil
		}
		time.Sleep(25 * time.Millisecond)
	}
	return fmt.Errorf("OpenClipboard failed after retries")
}

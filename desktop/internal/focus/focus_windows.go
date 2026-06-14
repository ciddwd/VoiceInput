//go:build windows

package focus

import (
	"path/filepath"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	modUser32                    = syscall.NewLazyDLL("user32.dll")
	procGetForegroundWindow      = modUser32.NewProc("GetForegroundWindow")
	procGetWindowTextW           = modUser32.NewProc("GetWindowTextW")
	procGetWindowThreadProcessID = modUser32.NewProc("GetWindowThreadProcessId")
)

type winDetector struct{}

func newPlatform() Detector { return &winDetector{} }

func (winDetector) Current() Info {
	hwnd, _, _ := procGetForegroundWindow.Call()
	if hwnd == 0 {
		return Info{}
	}
	var info Info

	// Title via GetWindowTextW
	buf := make([]uint16, 512)
	n, _, _ := procGetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n > 0 {
		info.AppName = windows.UTF16ToString(buf[:n])
	}

	// Process name via OpenProcess + QueryFullProcessImageNameW
	var pid uint32
	procGetWindowThreadProcessID.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
	if pid != 0 {
		h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
		if err == nil {
			var pbuf [windows.MAX_PATH]uint16
			pn := uint32(len(pbuf))
			if err := windows.QueryFullProcessImageName(h, 0, &pbuf[0], &pn); err == nil {
				full := windows.UTF16ToString(pbuf[:pn])
				info.ProcessName = filepath.Base(full)
			}
			windows.CloseHandle(h)
		}
	}
	return info
}

func (winDetector) Close() error { return nil }

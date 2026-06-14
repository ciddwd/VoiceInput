//go:build windows

package transport

import "golang.org/x/sys/windows"

func enableBroadcast(fd uintptr) error {
	return windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_BROADCAST, 1)
}

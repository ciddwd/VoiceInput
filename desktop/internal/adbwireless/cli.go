package adbwireless

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// DefaultBinary is the executable we shell out to. Override via SetBinary if
// the user has a non-standard install (Android Studio bundle, manual path).
var DefaultBinary = "adb"

// PairResult is what AdbPair returns to the UI: the raw "Successfully paired
// to ..." string lets the user verify, plus the parsed GUID for callers that
// want to remember devices.
type PairResult struct {
	Address string `json:"address"`
	Raw     string `json:"raw"`
	GUID    string `json:"guid,omitempty"`
}

// CLI wraps `adb` invocations. All methods are safe for concurrent use.
type CLI struct {
	bin string
}

func NewCLI(binary string) *CLI {
	if binary == "" {
		binary = DefaultBinary
	}
	return &CLI{bin: binary}
}

func (c *CLI) Binary() string { return c.bin }

// Version returns the first line of `adb version`. Empty string + error if
// adb isn't on PATH at all.
func (c *CLI) Version(ctx context.Context) (string, error) {
	out, err := c.run(ctx, 8*time.Second, "version")
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			return line, nil
		}
	}
	return strings.TrimSpace(out), nil
}

// Pair shells out to `adb pair <addr> <code>`. adb's interactive form ("Enter
// pairing code:") is avoided by passing the code as a positional argument,
// which works since platform-tools 33+.
func (c *CLI) Pair(ctx context.Context, addr, code string) (PairResult, error) {
	if addr == "" {
		return PairResult{}, errors.New("address required")
	}
	if code == "" {
		return PairResult{}, errors.New("pairing code required")
	}
	// adb pair blocks until either success or a fault; a tight cap (15 s) is
	// enough since the device is on the LAN and pairing-port handshakes are
	// fast or instantly fail.
	out, err := c.run(ctx, 15*time.Second, "pair", addr, code)
	res := PairResult{Address: addr, Raw: strings.TrimSpace(out)}
	if err != nil {
		return res, err
	}
	// Parse the guid the daemon reports back; useful for future "forget".
	if i := strings.Index(out, "guid="); i >= 0 {
		tail := out[i+len("guid="):]
		if j := strings.IndexAny(tail, "]\r\n"); j >= 0 {
			res.GUID = strings.TrimSpace(tail[:j])
		}
	}
	return res, nil
}

// Connect shells out to `adb connect <addr>`. Returns the raw daemon reply
// ("connected to ..." / "failed to connect ...") for the UI to show as-is.
func (c *CLI) Connect(ctx context.Context, addr string) (string, error) {
	if addr == "" {
		return "", errors.New("address required")
	}
	out, err := c.run(ctx, 10*time.Second, "connect", addr)
	return strings.TrimSpace(out), err
}

// Disconnect cuts a single device. Pass "" to disconnect all.
func (c *CLI) Disconnect(ctx context.Context, addr string) (string, error) {
	args := []string{"disconnect"}
	if addr != "" {
		args = append(args, addr)
	}
	out, err := c.run(ctx, 6*time.Second, args...)
	return strings.TrimSpace(out), err
}

// Device is one row of `adb devices -l` after parsing.
type Device struct {
	Serial  string `json:"serial"`
	State   string `json:"state"`
	Product string `json:"product,omitempty"`
	Model   string `json:"model,omitempty"`
	Device  string `json:"device,omitempty"`
}

// Devices lists every adb client currently registered with the local daemon.
// Returns wireless and USB devices alike; the caller filters on Serial format
// ("ip:port") if it only wants wireless ones.
func (c *CLI) Devices(ctx context.Context) ([]Device, error) {
	out, err := c.run(ctx, 6*time.Second, "devices", "-l")
	if err != nil {
		return nil, err
	}
	// Start from an empty (non-nil) slice: an empty `adb devices -l` would
	// otherwise leave this nil, which Wails serialises as JSON null and makes
	// the React side blow up on devices.length.
	devs := []Device{}
	for _, raw := range strings.Split(out, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "List of devices") || strings.HasPrefix(line, "*") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		d := Device{Serial: fields[0], State: fields[1]}
		for _, f := range fields[2:] {
			switch {
			case strings.HasPrefix(f, "product:"):
				d.Product = strings.TrimPrefix(f, "product:")
			case strings.HasPrefix(f, "model:"):
				d.Model = strings.TrimPrefix(f, "model:")
			case strings.HasPrefix(f, "device:"):
				d.Device = strings.TrimPrefix(f, "device:")
			}
		}
		devs = append(devs, d)
	}
	return devs, nil
}

func (c *CLI) run(parent context.Context, timeout time.Duration, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.bin, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	out := stdout.String()
	if errStr := strings.TrimSpace(stderr.String()); errStr != "" {
		// adb mixes useful info into stderr; surface it to the caller.
		if out != "" {
			out += "\n" + errStr
		} else {
			out = errStr
		}
	}
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return out, fmt.Errorf("%s %s timed out after %s", c.bin, strings.Join(args, " "), timeout)
		}
		return out, fmt.Errorf("%s %s: %w", c.bin, strings.Join(args, " "), err)
	}
	return out, nil
}

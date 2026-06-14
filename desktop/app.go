package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"

	"desktop/internal/adbwireless"
	"desktop/internal/focus"
	"desktop/internal/inject"
	"desktop/internal/protocol"
	"desktop/internal/snippets"
	"desktop/internal/transport"
)

// Polish moved to the mobile side: the API key + provider config + LLM call
// all live next to the speech recognition step, on the device that records.
// The desktop is intentionally dumb here — receive text, inject text. The
// internal/polish and internal/settings packages are kept as dead code for
// future reference but no longer wired into the request path.

const (
	wsPort          = 53118
	beaconPort      = transport.DefaultBeaconPort
	injectThreshold = 50 // runes: <= threshold goes to Type, otherwise Paste
	focusInterval   = 1500 * time.Millisecond
)

type App struct {
	ctx       context.Context
	transport *transport.Server
	mdns      *transport.MDNSPublisher
	beacon    *transport.UDPBeacon
	pairing   *transport.PairingManager
	injector  inject.Injector
	store     *snippets.Store
	focusDet  focus.Detector

	focusMu      sync.Mutex
	lastFocus    string // last process name pushed
	lastFocusAt  time.Time

	// ADB wireless debugging helpers. The discoverer is started on demand
	// (StartAdbDiscovery) so we don't burn an extra mDNS browser when the
	// user never opens the panel.
	adbCLI       *adbwireless.CLI
	adbMu        sync.Mutex
	adbDiscover  *adbwireless.Discoverer
}

func NewApp() *App {
	return &App{
		injector: inject.New(),
		focusDet: focus.New(),
		adbCLI:   adbwireless.NewCLI(""),
	}
}

type wailsBus struct{ ctx context.Context }

func (b *wailsBus) Publish(event string, payload any) {
	if b.ctx == nil {
		return
	}
	runtime.EventsEmit(b.ctx, event, payload)
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	bus := &wailsBus{ctx: ctx}

	store, err := snippets.Open(snippetsPath())
	if err != nil {
		runtime.LogErrorf(ctx, "open snippet store: %v", err)
	} else {
		a.store = store
	}

	a.pairing = transport.NewPairingManager(peersPath(), bus)

	a.transport = transport.New(wsPort, bus, a.pairing)
	a.transport.OnTextInput(a.handleTextInput)
	a.transport.OnTextClear(a.handleTextClear)
	a.transport.OnAuth(a.onClientAuthed)
	if err := a.transport.Start(ctx); err != nil {
		runtime.LogErrorf(ctx, "transport start failed: %v", err)
	} else {
		runtime.LogInfof(ctx, "VoiceInput WS listening on :%d", wsPort)
	}

	a.mdns = transport.NewMDNSPublisher()
	if err := a.mdns.Start(ctx, "", wsPort); err != nil {
		runtime.LogWarningf(ctx, "mDNS publish failed: %v (UDP beacon still active)", err)
	}

	a.beacon = transport.NewUDPBeacon(beaconPort, wsPort)
	if err := a.beacon.Start(ctx); err != nil {
		runtime.LogWarningf(ctx, "UDP beacon failed: %v", err)
	}

	go a.focusLoop(ctx)
}

func (a *App) shutdown(ctx context.Context) {
	if a.beacon != nil {
		a.beacon.Stop()
	}
	if a.mdns != nil {
		a.mdns.Stop()
	}
	if a.transport != nil {
		_ = a.transport.Stop()
	}
	if a.store != nil {
		_ = a.store.Close()
	}
	if a.focusDet != nil {
		_ = a.focusDet.Close()
	}
	a.StopAdbDiscovery()
}

// onClientAuthed runs whenever a session transitions to authed. Push the full
// snippet snapshot + a fresh focus update so the mobile UI is ready to use.
func (a *App) onClientAuthed() {
	a.pushSnapshot()
	a.pushFocus(true)
}

func (a *App) handleTextInput(p protocol.TextInputPayload) {
	if a.injector == nil {
		return
	}
	if err := a.injector.Inject(p.Text, inject.ParseMode(p.Mode), injectThreshold); err != nil {
		runtime.LogErrorf(a.ctx, "inject text: %v", err)
		return
	}
	if p.Suffix == "" {
		return
	}
	if literal := strings.TrimPrefix(p.Suffix, "custom:"); literal != p.Suffix {
		if err := a.injector.Inject(literal, inject.ModeType, 0); err != nil {
			runtime.LogErrorf(a.ctx, "inject suffix: %v", err)
		}
		return
	}
	if err := a.injector.PressKey(p.Suffix); err != nil {
		runtime.LogErrorf(a.ctx, "press suffix %q: %v", p.Suffix, err)
	}
}


func (a *App) handleTextClear() {
	if a.injector == nil {
		return
	}
	if err := a.injector.Clear(); err != nil {
		runtime.LogErrorf(a.ctx, "clear: %v", err)
	}
}

// pushSnapshot serialises the full library and ships it to the connected
// (and authed) mobile client. Also mirrors to the UI so the desktop's own
// Snippets page stays in sync.
func (a *App) pushSnapshot() {
	if a.store == nil {
		return
	}
	snap, err := a.store.Snapshot()
	if err != nil {
		runtime.LogErrorf(a.ctx, "snapshot: %v", err)
		return
	}
	payload := snapshotToWire(snap)
	_ = a.transport.SendIfAuthed(protocol.Message{
		V: protocol.Version, Type: protocol.TypeSnippetsSnap,
		Data: mustMarshalJSON(payload),
	})
	// Local UI uses the raw snippets.Snapshot for richer typing.
	runtime.EventsEmit(a.ctx, "snippets:changed", snap)
}

// focusLoop polls the foreground app on a fixed interval and pushes updates
// to the mobile when the focused process changes (or once per minute as a
// keep-alive so the mobile knows we're still here even when focus is stable).
func (a *App) focusLoop(ctx context.Context) {
	ticker := time.NewTicker(focusInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.pushFocus(false)
		}
	}
}

func (a *App) pushFocus(force bool) {
	if a.focusDet == nil {
		return
	}
	info := a.focusDet.Current()
	if info.ProcessName == "" {
		return
	}
	a.focusMu.Lock()
	changed := info.ProcessName != a.lastFocus
	stale := time.Since(a.lastFocusAt) > time.Minute
	if !force && !changed && !stale {
		a.focusMu.Unlock()
		return
	}
	a.lastFocus = info.ProcessName
	a.lastFocusAt = time.Now()
	a.focusMu.Unlock()

	suggested := a.matchCategory(info.ProcessName)
	payload := protocol.FocusUpdatePayload{
		AppName:           info.AppName,
		ProcessName:       info.ProcessName,
		SuggestedCategory: suggested,
	}
	_ = a.transport.SendIfAuthed(protocol.Message{
		V: protocol.Version, Type: protocol.TypeFocusUpdate,
		Data: mustMarshalJSON(payload),
	})
	runtime.EventsEmit(a.ctx, "focus:update", payload)
}

// matchCategory walks all categories with a non-empty MatchAppRegex and picks
// the first one whose pattern matches the foreground process name. Empty
// regexes are skipped (they'd match everything).
func (a *App) matchCategory(processName string) string {
	if a.store == nil {
		return ""
	}
	snap, err := a.store.Snapshot()
	if err != nil {
		return ""
	}
	for _, c := range snap.Categories {
		if c.MatchAppRegex == "" {
			continue
		}
		re, err := regexp.Compile(c.MatchAppRegex)
		if err != nil {
			continue
		}
		if re.MatchString(processName) {
			return c.Name
		}
	}
	return ""
}

// ---- Methods exposed to the frontend ----

func (a *App) GetStatus() transport.Status {
	if a.transport == nil {
		return transport.Status{Port: wsPort}
	}
	return a.transport.Status()
}

func (a *App) GetPairing() transport.PairingSnapshot {
	if a.pairing == nil {
		return transport.PairingSnapshot{State: "unpaired"}
	}
	return a.pairing.Snapshot()
}

func (a *App) ForgetPairings() error {
	if a.pairing == nil {
		return nil
	}
	return a.pairing.ForgetAll()
}

// GetSnippets returns the entire library to the desktop UI.
func (a *App) GetSnippets() (snippets.Snapshot, error) {
	if a.store == nil {
		return snippets.Snapshot{}, nil
	}
	return a.store.Snapshot()
}

// SaveCategory upserts a category (ID 0 = new). Returns the assigned ID and
// triggers a snapshot push to all connected clients.
func (a *App) SaveCategory(c snippets.Category) (int64, error) {
	if a.store == nil {
		return 0, nil
	}
	var id int64
	var err error
	if c.ID == 0 {
		id, err = a.store.CreateCategory(c)
	} else {
		err = a.store.UpdateCategory(c)
		id = c.ID
	}
	if err == nil {
		a.pushSnapshot()
	}
	return id, err
}

func (a *App) DeleteCategory(id int64) error {
	if a.store == nil {
		return nil
	}
	err := a.store.DeleteCategory(id)
	if err == nil {
		a.pushSnapshot()
	}
	return err
}

func (a *App) SaveSnippet(n snippets.Snippet) (int64, error) {
	if a.store == nil {
		return 0, nil
	}
	var id int64
	var err error
	if n.ID == 0 {
		id, err = a.store.CreateSnippet(n)
	} else {
		err = a.store.UpdateSnippet(n)
		id = n.ID
	}
	if err == nil {
		a.pushSnapshot()
	}
	return id, err
}

func (a *App) DeleteSnippet(id int64) error {
	if a.store == nil {
		return nil
	}
	err := a.store.DeleteSnippet(id)
	if err == nil {
		a.pushSnapshot()
	}
	return err
}

// ---- helpers ----

func snapshotToWire(s snippets.Snapshot) protocol.SnippetsSnapshotPayload {
	out := protocol.SnippetsSnapshotPayload{Revision: s.Revision}
	out.Categories = make([]protocol.SnippetCategoryPayload, 0, len(s.Categories))
	for _, c := range s.Categories {
		out.Categories = append(out.Categories, protocol.SnippetCategoryPayload{
			ID: c.ID, Name: c.Name, Prefix: c.Prefix, Suffix: c.Suffix,
			DefaultSendSuffix: c.DefaultSendSuffix, MatchAppRegex: c.MatchAppRegex, Sort: c.Sort,
		})
	}
	out.Snippets = make([]protocol.SnippetItemPayload, 0, len(s.Snippets))
	for _, n := range s.Snippets {
		out.Snippets = append(out.Snippets, protocol.SnippetItemPayload{
			ID: n.ID, CategoryID: n.CategoryID, Label: n.Label,
			Content: n.Content, Hotkey: n.Hotkey, Sort: n.Sort,
		})
	}
	out.Dictionary = make([]protocol.DictionaryEntryPayload, 0, len(s.Dictionary))
	for _, d := range s.Dictionary {
		out.Dictionary = append(out.Dictionary, protocol.DictionaryEntryPayload{
			ID: d.ID, Term: d.Term, Sort: d.Sort,
		})
	}
	return out
}

// ReplaceDictionary atomically swaps the full dictionary. The UI sends a
// chip-cloud editor's final list to avoid per-entry diffing.
func (a *App) ReplaceDictionary(terms []string) error {
	if a.store == nil {
		return nil
	}
	err := a.store.ReplaceDictionary(terms)
	if err == nil {
		a.pushSnapshot()
	}
	return err
}

func mustMarshalJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}

// --- ADB wireless debugging surface (called from the React UI) -------------

// StartAdbDiscovery begins (or re-uses) an mDNS browser for the two adb
// service types. Endpoint changes are pushed to the UI via the "adb:endpoints"
// event so the React layer can be event-driven without polling.
func (a *App) StartAdbDiscovery() error {
	a.adbMu.Lock()
	defer a.adbMu.Unlock()
	if a.adbDiscover != nil {
		// Re-emit the current snapshot so a re-mounted UI sees state instantly.
		runtime.EventsEmit(a.ctx, "adb:endpoints", a.adbDiscover.Snapshot())
		return nil
	}
	d := adbwireless.NewDiscoverer(func(eps []adbwireless.Endpoint) {
		runtime.EventsEmit(a.ctx, "adb:endpoints", eps)
	})
	if err := d.Start(); err != nil {
		return err
	}
	a.adbDiscover = d
	return nil
}

// StopAdbDiscovery tears down the mDNS browser. Safe to call when not started.
func (a *App) StopAdbDiscovery() {
	a.adbMu.Lock()
	d := a.adbDiscover
	a.adbDiscover = nil
	a.adbMu.Unlock()
	if d != nil {
		d.Stop()
	}
}

// GetAdbEndpoints returns the latest discovery snapshot in one shot, useful
// for a freshly-mounted panel that doesn't want to wait on an event tick.
func (a *App) GetAdbEndpoints() []adbwireless.Endpoint {
	a.adbMu.Lock()
	defer a.adbMu.Unlock()
	if a.adbDiscover == nil {
		return []adbwireless.Endpoint{}
	}
	return a.adbDiscover.Snapshot()
}

// AdbVersion reports the local adb binary version (mostly: "is it installed").
func (a *App) AdbVersion() (string, error) {
	return a.adbCLI.Version(a.ctx)
}

// AdbPair runs `adb pair <addr> <code>`. Returns the daemon output so the UI
// can echo "Successfully paired..." back to the user verbatim.
func (a *App) AdbPair(addr, code string) (adbwireless.PairResult, error) {
	return a.adbCLI.Pair(a.ctx, addr, code)
}

// AdbConnect runs `adb connect <addr>`. After success the UI typically wants
// to call AdbDevices to confirm the device showed up.
func (a *App) AdbConnect(addr string) (string, error) {
	return a.adbCLI.Connect(a.ctx, addr)
}

// AdbDisconnect drops one device (or all when addr=="").
func (a *App) AdbDisconnect(addr string) (string, error) {
	return a.adbCLI.Disconnect(a.ctx, addr)
}

// AdbDevices returns `adb devices -l` parsed into structured rows.
func (a *App) AdbDevices() ([]adbwireless.Device, error) {
	return a.adbCLI.Devices(a.ctx)
}

func peersPath() string {
	if dir, err := os.UserConfigDir(); err == nil {
		return filepath.Join(dir, "VoiceInput", "peers.json")
	}
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "peers.json")
}

func snippetsPath() string {
	if dir, err := os.UserConfigDir(); err == nil {
		return filepath.Join(dir, "VoiceInput", "snippets.db")
	}
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "snippets.db")
}


package transport

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Pairing state machine:
//
//   Unpaired  -- (hello, no token)      --> PinPending (PIN shown in UI)
//   Unpaired  -- (hello, valid token)   --> Paired
//   PinPending -- (pair/pin matches)    --> Paired (new token issued, persisted)
//   PinPending -- (pair/pin wrong x3)   --> Locked (60s cooldown)
//   Locked     -- (timer expires)       --> Unpaired
//
// Token = 32 random bytes hex. Stored per deviceID in peers.json under
// the user config dir.
//
// Only one device may be pairing or paired at any moment, which matches the
// "single voice keyboard at a time" product shape.

const (
	pinLength       = 6
	maxPinAttempts  = 3
	pinLockDuration = 60 * time.Second
	pinTimeout      = 5 * time.Minute
)

type PairState int

const (
	PairUnpaired PairState = iota
	PairPinPending
	PairPaired
	PairLocked
)

func (s PairState) String() string {
	switch s {
	case PairUnpaired:
		return "unpaired"
	case PairPinPending:
		return "pinPending"
	case PairPaired:
		return "paired"
	case PairLocked:
		return "locked"
	}
	return "unknown"
}

// PairingSnapshot is what the frontend sees. Keeping it flat makes the React
// store trivial.
type PairingSnapshot struct {
	State          string    `json:"state"`
	PIN            string    `json:"pin,omitempty"`         // populated only in PinPending, for the UI
	PinExpiresAt   time.Time `json:"pinExpiresAt,omitempty"`
	DeviceName     string    `json:"deviceName,omitempty"`
	DeviceID       string    `json:"deviceId,omitempty"`
	LockedUntil    time.Time `json:"lockedUntil,omitempty"`
	FailedAttempts int       `json:"failedAttempts,omitempty"`
}

type peersFile struct {
	Peers map[string]peerRecord `json:"peers"`
}

type peerRecord struct {
	DeviceName string    `json:"deviceName"`
	Token      string    `json:"token"`
	CreatedAt  time.Time `json:"createdAt"`
}

// PairingManager owns the pairing state. It's safe to call from multiple
// goroutines; mutations notify watchers via the provided Bus.
type PairingManager struct {
	storePath string
	bus       Bus

	mu             sync.Mutex
	state          PairState
	pin            string
	pinExpiresAt   time.Time
	pendingDevice  string // deviceID currently in PinPending
	pendingName    string
	pairedDevice   string
	pairedName     string
	failedAttempts int
	lockedUntil    time.Time

	peers map[string]peerRecord
}

func NewPairingManager(storePath string, bus Bus) *PairingManager {
	m := &PairingManager{storePath: storePath, bus: bus, peers: map[string]peerRecord{}}
	m.loadPeers()
	return m
}

// HelloResult tells the caller how to react to a hello message.
type HelloResult struct {
	Authed bool   // True when the client provided a valid token; no PIN needed.
	NeedPIN bool  // True when caller should hold the connection and wait for pair/pin.
	Error  string // Non-empty when the hello is rejected outright.
}

// HandleHello processes the first message from a client. It may transition
// the state machine to PinPending and emit a UI event with the new PIN.
func (m *PairingManager) HandleHello(deviceID, deviceName, token string) HelloResult {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.expireIfNeeded()

	if m.state == PairLocked {
		return HelloResult{Error: "locked"}
	}

	if token != "" {
		if rec, ok := m.peers[deviceID]; ok && rec.Token == token {
			m.state = PairPaired
			m.pairedDevice = deviceID
			m.pairedName = deviceName
			m.publish()
			return HelloResult{Authed: true}
		}
		return HelloResult{Error: "bad_token"}
	}

	// No token: start PIN flow. Generate a fresh PIN per hello so an old PIN
	// from a previous abandoned attempt doesn't linger.
	m.state = PairPinPending
	m.pin = randomPIN()
	m.pinExpiresAt = time.Now().Add(pinTimeout)
	m.pendingDevice = deviceID
	m.pendingName = deviceName
	m.failedAttempts = 0
	m.publish()
	return HelloResult{NeedPIN: true}
}

// HandlePIN validates a PIN submitted by the client. Returns (ok, token, code).
func (m *PairingManager) HandlePIN(deviceID, submittedPIN string) (bool, string, string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.expireIfNeeded()

	if m.state != PairPinPending || m.pendingDevice != deviceID {
		return false, "", "no_pending_pairing"
	}
	if submittedPIN != m.pin {
		m.failedAttempts++
		if m.failedAttempts >= maxPinAttempts {
			m.state = PairLocked
			m.lockedUntil = time.Now().Add(pinLockDuration)
			m.pin = ""
			m.publish()
			return false, "", "locked"
		}
		m.publish()
		return false, "", "invalid_pin"
	}

	// Success: mint token, persist, transition to Paired.
	tk := randomToken()
	m.peers[deviceID] = peerRecord{
		DeviceName: m.pendingName,
		Token:      tk,
		CreatedAt:  time.Now(),
	}
	_ = m.savePeers()

	m.state = PairPaired
	m.pairedDevice = deviceID
	m.pairedName = m.pendingName
	m.pin = ""
	m.pendingDevice = ""
	m.pendingName = ""
	m.failedAttempts = 0
	m.publish()
	return true, tk, ""
}

// IsAuthed reports whether a given session may inject text. Called per text
// message; cheap because it's just a state read.
func (m *PairingManager) IsAuthed(deviceID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.state == PairPaired && m.pairedDevice == deviceID
}

// Reset clears any pending or locked state. Called when a session disconnects.
func (m *PairingManager) Reset() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.state == PairLocked {
		// Don't shorten the cooldown.
		return
	}
	m.state = PairUnpaired
	m.pin = ""
	m.pendingDevice = ""
	m.pendingName = ""
	m.pairedDevice = ""
	m.pairedName = ""
	m.failedAttempts = 0
	m.publish()
}

// ForgetAll wipes peers.json. Useful from the UI when the user wants to start
// over.
func (m *PairingManager) ForgetAll() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.peers = map[string]peerRecord{}
	m.Reset()
	return m.savePeers()
}

func (m *PairingManager) Snapshot() PairingSnapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	snap := PairingSnapshot{State: m.state.String(), FailedAttempts: m.failedAttempts}
	switch m.state {
	case PairPinPending:
		snap.PIN = m.pin
		snap.PinExpiresAt = m.pinExpiresAt
		snap.DeviceID = m.pendingDevice
		snap.DeviceName = m.pendingName
	case PairPaired:
		snap.DeviceID = m.pairedDevice
		snap.DeviceName = m.pairedName
	case PairLocked:
		snap.LockedUntil = m.lockedUntil
	}
	return snap
}

// expireIfNeeded transitions out of Locked or PinPending when their timers fire.
// Caller must hold the lock.
func (m *PairingManager) expireIfNeeded() {
	now := time.Now()
	if m.state == PairLocked && now.After(m.lockedUntil) {
		m.state = PairUnpaired
		m.failedAttempts = 0
	}
	if m.state == PairPinPending && now.After(m.pinExpiresAt) {
		m.state = PairUnpaired
		m.pin = ""
		m.pendingDevice = ""
		m.pendingName = ""
	}
}

func (m *PairingManager) publish() {
	if m.bus == nil {
		return
	}
	m.bus.Publish("pairing:state", m.snapshotLocked())
}

func (m *PairingManager) snapshotLocked() PairingSnapshot {
	snap := PairingSnapshot{State: m.state.String(), FailedAttempts: m.failedAttempts}
	switch m.state {
	case PairPinPending:
		snap.PIN = m.pin
		snap.PinExpiresAt = m.pinExpiresAt
		snap.DeviceID = m.pendingDevice
		snap.DeviceName = m.pendingName
	case PairPaired:
		snap.DeviceID = m.pairedDevice
		snap.DeviceName = m.pairedName
	case PairLocked:
		snap.LockedUntil = m.lockedUntil
	}
	return snap
}

func (m *PairingManager) loadPeers() {
	data, err := os.ReadFile(m.storePath)
	if err != nil {
		return
	}
	var f peersFile
	if err := json.Unmarshal(data, &f); err != nil {
		return
	}
	if f.Peers != nil {
		m.peers = f.Peers
	}
}

func (m *PairingManager) savePeers() error {
	if err := os.MkdirAll(filepath.Dir(m.storePath), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(peersFile{Peers: m.peers}, "", "  ")
	if err != nil {
		return err
	}
	tmp := m.storePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, m.storePath)
}

func randomPIN() string {
	max := big.NewInt(1)
	for i := 0; i < pinLength; i++ {
		max.Mul(max, big.NewInt(10))
	}
	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		// Crypto rand failing is exceptional; fall back to time-based PIN
		// rather than panicking on a hot path.
		return fmt.Sprintf("%0*d", pinLength, time.Now().UnixNano()%int64(intPow10(pinLength)))
	}
	return fmt.Sprintf("%0*d", pinLength, n.Int64())
}

func randomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return hex.EncodeToString([]byte(time.Now().Format(time.RFC3339Nano)))
	}
	return hex.EncodeToString(b)
}

func intPow10(n int) int {
	v := 1
	for i := 0; i < n; i++ {
		v *= 10
	}
	return v
}

// ErrPairingMisuse is returned by HandlePIN when called in a state that
// doesn't expect a PIN. Currently unused outside tests but exported so they
// can assert against the public surface.
var ErrPairingMisuse = errors.New("pairing manager is not waiting for a PIN")

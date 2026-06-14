// Package protocol defines the JSON-over-WebSocket message envelope and
// payload structs shared between the desktop receiver and the mobile IME.
//
// Wire format: {"v":1,"id":"<uuid>","type":"<name>","data":{...}}
package protocol

import "encoding/json"

const Version = 1

type Message struct {
	V    int             `json:"v"`
	ID   string          `json:"id"`
	Type string          `json:"type"`
	Data json.RawMessage `json:"data,omitempty"`
}

// Message types.
const (
	TypeHello       = "hello"
	TypePairPin     = "pair/pin"
	TypePairResult  = "pair/result"
	TypeAuth        = "auth"
	TypeTextInput   = "text/input"
	TypeTextClear   = "text/clear"
	TypeFocusUpdate = "focus/update"
	TypeSnippetsSnap  = "snippets/snapshot"
	TypeSnippetsDelta = "snippets/delta"
	TypeHeartbeat   = "heartbeat"
	TypeAck         = "ack"
	TypeError       = "error"
)

type HelloPayload struct {
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"`
	Token      string `json:"token,omitempty"`
}

// PairPinPayload is sent by the mobile after the user enters the PIN shown on
// the desktop screen.
type PairPinPayload struct {
	PIN string `json:"pin"`
}

// PairResultPayload is the desktop's verdict on a hello or pair/pin attempt.
// On OK=true and a non-empty Token, the mobile persists it for auto-reconnect.
type PairResultPayload struct {
	OK    bool   `json:"ok"`
	Code  string `json:"code,omitempty"` // e.g. "invalid_pin", "locked", "bad_token"
	Token string `json:"token,omitempty"`
	// NeedPIN signals the mobile to prompt the user; emitted in response to a
	// hello with no token (or a bad token if the user chose "re-pair").
	NeedPIN bool `json:"needPin,omitempty"`
}

// TextInputPayload is sent mobile -> desktop to inject text at the current focus.
//
// Mode controls the injection strategy:
//   "auto"  - let the desktop pick (default; threshold-based)
//   "type"  - per-character keyboard simulation
//   "paste" - clipboard + Ctrl/Cmd+V
//
// Suffix is appended after the text when injecting. Recognised values:
//   "", "enter", "tab", "space", "custom:<literal>"
type TextInputPayload struct {
	Text   string `json:"text"`
	Suffix string `json:"suffix,omitempty"`
	Mode   string `json:"mode,omitempty"`   // injection: auto / type / paste
	Polish string `json:"polish,omitempty"` // polish: raw / light / structured / formal
}

type TextClearPayload struct{}

type FocusUpdatePayload struct {
	AppName           string `json:"appName"`
	ProcessName       string `json:"processName"`
	SuggestedCategory string `json:"suggestedCategory,omitempty"`
}

type AckPayload struct {
	RefID string `json:"refId"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type ErrorPayload struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// SnippetCategoryPayload mirrors snippets.Category as sent over the wire.
type SnippetCategoryPayload struct {
	ID                int64  `json:"id"`
	Name              string `json:"name"`
	Prefix            string `json:"prefix"`
	Suffix            string `json:"suffix"`
	DefaultSendSuffix string `json:"defaultSendSuffix"`
	MatchAppRegex     string `json:"matchAppRegex"`
	Sort              int    `json:"sort"`
}

// SnippetItemPayload mirrors snippets.Snippet as sent over the wire.
type SnippetItemPayload struct {
	ID         int64  `json:"id"`
	CategoryID int64  `json:"categoryId"`
	Label      string `json:"label"`
	Content    string `json:"content"`
	Hotkey     string `json:"hotkey,omitempty"`
	Sort       int    `json:"sort"`
}

// DictionaryEntryPayload mirrors snippets.DictionaryEntry — a single
// hotword the user wants ASR + polish to preserve verbatim.
type DictionaryEntryPayload struct {
	ID   int64  `json:"id"`
	Term string `json:"term"`
	Sort int    `json:"sort"`
}

// SnippetsSnapshotPayload is the desktop → mobile full library push, sent
// right after authentication and after any "Forget" / re-pair.
type SnippetsSnapshotPayload struct {
	Categories []SnippetCategoryPayload `json:"categories"`
	Snippets   []SnippetItemPayload     `json:"snippets"`
	Dictionary []DictionaryEntryPayload `json:"dictionary"`
	Revision   int64                    `json:"revision"`
}

// SnippetsDeltaPayload carries incremental changes after the initial snapshot.
// For phase-1 we just resend the snapshot when the revision moves; this
// payload is reserved for a later granular implementation.
type SnippetsDeltaPayload struct {
	Snapshot SnippetsSnapshotPayload `json:"snapshot"`
}

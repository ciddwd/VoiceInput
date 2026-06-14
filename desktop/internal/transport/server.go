// Package transport implements the local-network WebSocket server that the
// mobile IME connects to. It manages a single-active-client session, pairs
// new devices via PIN, and forwards business-relevant messages to the app
// layer for injection while mirroring them to the UI bus.
package transport

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"desktop/internal/protocol"
)

// Bus decouples transport from the Wails runtime so this package stays
// testable without a real frontend. The app layer wires Wails' EventsEmit
// into Publish.
type Bus interface {
	Publish(event string, payload any)
}

// Status is a snapshot of the server state, suitable to be serialised to the
// frontend or used in tests.
type Status struct {
	Address           string    `json:"address"`
	Port              int       `json:"port"`
	LANIPs            []string  `json:"lanIps"`
	Connected         bool      `json:"connected"`
	Authed            bool      `json:"authed"`
	ConnectedDevice   string    `json:"connectedDevice,omitempty"`
	ConnectedDeviceID string    `json:"connectedDeviceId,omitempty"`
	ConnectedAt       time.Time `json:"connectedAt,omitempty"`
}

// Server holds the WS listener and the (single) live session.
type Server struct {
	port    int
	bus     Bus
	pairing *PairingManager

	onTextInput func(protocol.TextInputPayload)
	onTextClear func()
	onAuth      func()

	upgrader websocket.Upgrader
	srv      *http.Server

	mu       sync.RWMutex
	sessions map[*session]struct{} // all live clients; the main app and the IME
	// connect as separate sessions and must coexist instead of displacing.
}

type session struct {
	conn        *websocket.Conn
	deviceID    string
	deviceName  string
	authed      bool
	connectedAt time.Time
	writeMu     sync.Mutex
}

// New returns a server that will listen on the given port when Start is called.
// pairing may be nil for tests that don't need auth.
func New(port int, bus Bus, pairing *PairingManager) *Server {
	return &Server{
		port:     port,
		bus:      bus,
		pairing:  pairing,
		sessions: map[*session]struct{}{},
		upgrader: websocket.Upgrader{
			CheckOrigin:     func(r *http.Request) bool { return true },
			ReadBufferSize:  4096,
			WriteBufferSize: 4096,
		},
	}
}

func (s *Server) OnTextInput(fn func(protocol.TextInputPayload)) { s.onTextInput = fn }
func (s *Server) OnTextClear(fn func())                          { s.onTextClear = fn }

func (s *Server) Start(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWS)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	addr := fmt.Sprintf("0.0.0.0:%d", s.port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", addr, err)
	}

	s.srv = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = s.srv.Serve(ln) }()
	s.publishStatus()
	return nil
}

func (s *Server) Stop() error {
	s.closeAllSessions("server stopping")
	if s.srv == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return s.srv.Shutdown(ctx)
}

func (s *Server) Status() Status {
	st := Status{
		Address: "0.0.0.0",
		Port:    s.port,
		LANIPs:  LANIPv4s(),
	}
	s.mu.RLock()
	for sess := range s.sessions {
		st.Connected = true
		st.ConnectedDevice = sess.deviceName
		st.ConnectedDeviceID = sess.deviceID
		st.ConnectedAt = sess.connectedAt
		// Prefer an authed session for the displayed device; any will do.
		if sess.authed {
			st.Authed = true
			break
		}
	}
	s.mu.RUnlock()
	return st
}

// Send pushes a server-originated message (e.g. focus/update) to every client.
func (s *Server) Send(msg protocol.Message) error {
	for _, sess := range s.snapshotSessions() {
		sess.writeMu.Lock()
		_ = sess.conn.WriteJSON(msg)
		sess.writeMu.Unlock()
	}
	return nil
}

// SendIfAuthed is like Send but skips when the session is still pre-auth.
// Used by background pushers (snippets snapshot, focus tick) that should not
// leak data to a not-yet-paired device.
func (s *Server) SendIfAuthed(msg protocol.Message) error {
	for _, sess := range s.snapshotSessions() {
		if !sess.authed {
			continue
		}
		sess.writeMu.Lock()
		_ = sess.conn.WriteJSON(msg)
		sess.writeMu.Unlock()
	}
	return nil
}

// OnAuth registers a callback fired the moment a session becomes authed
// (either via valid token at hello, or via successful PIN). The app layer
// uses this to push the snippet snapshot + a first focus update.
func (s *Server) OnAuth(fn func()) { s.onAuth = fn }

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}

	log.Printf("transport: ws upgrade ok from %s", r.RemoteAddr)
	// Clients coexist: the main app and the IME run as separate engines on the
	// phone and each opens its own session. We deliberately do NOT displace a
	// previous session here — that "single session, newest wins" rule was what
	// made the app and the IME endlessly kick each other offline (displaced loop).
	sess := &session{conn: conn, connectedAt: time.Now()}
	s.mu.Lock()
	s.sessions[sess] = struct{}{}
	s.mu.Unlock()
	s.publishStatus()

	defer func() {
		s.dropSession(sess, "client disconnected")
	}()

	conn.SetReadLimit(64 * 1024)
	const readDeadline = 90 * time.Second
	_ = conn.SetReadDeadline(time.Now().Add(readDeadline))
	// Client (Dart's IOWebSocketChannel) sends WS pings every 20 s. Gorilla's
	// default ping handler auto-sends a pong but does NOT refresh the read
	// deadline, so without this override the server kills the socket at the
	// 90 s mark even on a perfectly healthy connection.
	conn.SetPingHandler(func(appData string) error {
		_ = conn.SetReadDeadline(time.Now().Add(readDeadline))
		err := conn.WriteControl(websocket.PongMessage, []byte(appData),
			time.Now().Add(10*time.Second))
		if err == websocket.ErrCloseSent {
			return nil
		}
		return err
	})
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(readDeadline))
	})

	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			// Distinguish "client closed cleanly" from "we timed them out" so
			// the cause of a mysterious disconnect is visible in logs.
			if websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				log.Printf("transport: client closed: %v", err)
			} else {
				log.Printf("transport: read loop ended: %v", err)
			}
			return
		}
		var msg protocol.Message
		if err := json.Unmarshal(raw, &msg); err != nil {
			sendJSON(sess, protocol.Message{
				V: protocol.Version, Type: protocol.TypeError,
				Data: mustMarshal(protocol.ErrorPayload{Code: "bad_json", Message: err.Error()}),
			})
			continue
		}
		s.dispatch(sess, msg)
	}
}

func (s *Server) dispatch(sess *session, msg protocol.Message) {
	switch msg.Type {
	case protocol.TypeHello:
		s.handleHello(sess, msg)

	case protocol.TypePairPin:
		s.handlePairPin(sess, msg)

	case protocol.TypeHeartbeat:
		s.ack(sess, msg.ID, true, "")

	case protocol.TypeTextInput:
		if !sess.authed {
			s.ack(sess, msg.ID, false, "not_authed")
			return
		}
		var p protocol.TextInputPayload
		if err := json.Unmarshal(msg.Data, &p); err != nil {
			s.ack(sess, msg.ID, false, err.Error())
			return
		}
		if s.onTextInput != nil {
			s.onTextInput(p)
		}
		s.bus.Publish("transport:text_input", p)
		s.ack(sess, msg.ID, true, "")

	case protocol.TypeTextClear:
		if !sess.authed {
			s.ack(sess, msg.ID, false, "not_authed")
			return
		}
		if s.onTextClear != nil {
			s.onTextClear()
		}
		s.bus.Publish("transport:text_clear", nil)
		s.ack(sess, msg.ID, true, "")

	default:
		s.ack(sess, msg.ID, false, "unsupported type: "+msg.Type)
	}
}

func (s *Server) handleHello(sess *session, msg protocol.Message) {
	var p protocol.HelloPayload
	if err := json.Unmarshal(msg.Data, &p); err != nil {
		s.ack(sess, msg.ID, false, err.Error())
		return
	}
	sess.deviceID = p.DeviceID
	sess.deviceName = p.DeviceName
	log.Printf("transport: hello device=%q (id=%s) hasToken=%t",
		p.DeviceName, p.DeviceID, p.Token != "")

	if s.pairing == nil {
		// No-auth mode: useful for unit tests.
		sess.authed = true
		s.publishStatus()
		sendJSON(sess, protocol.Message{
			V: protocol.Version, Type: protocol.TypePairResult,
			Data: mustMarshal(protocol.PairResultPayload{OK: true}),
		})
		s.ack(sess, msg.ID, true, "")
		return
	}

	result := s.pairing.HandleHello(p.DeviceID, p.DeviceName, p.Token)
	switch {
	case result.Authed:
		sess.authed = true
		log.Printf("transport: authed via token device=%q", p.DeviceName)
		s.publishStatus()
		sendJSON(sess, protocol.Message{
			V: protocol.Version, Type: protocol.TypePairResult,
			Data: mustMarshal(protocol.PairResultPayload{OK: true, Token: p.Token}),
		})
		if s.onAuth != nil {
			go s.onAuth()
		}
	case result.NeedPIN:
		s.publishStatus()
		sendJSON(sess, protocol.Message{
			V: protocol.Version, Type: protocol.TypePairResult,
			Data: mustMarshal(protocol.PairResultPayload{OK: false, NeedPIN: true}),
		})
	case result.Error != "":
		sendJSON(sess, protocol.Message{
			V: protocol.Version, Type: protocol.TypePairResult,
			Data: mustMarshal(protocol.PairResultPayload{OK: false, Code: result.Error, NeedPIN: result.Error == "bad_token"}),
		})
	}
	s.ack(sess, msg.ID, true, "")
}

func (s *Server) handlePairPin(sess *session, msg protocol.Message) {
	if s.pairing == nil {
		s.ack(sess, msg.ID, false, "no_pairing_manager")
		return
	}
	var p protocol.PairPinPayload
	if err := json.Unmarshal(msg.Data, &p); err != nil {
		s.ack(sess, msg.ID, false, err.Error())
		return
	}
	ok, token, code := s.pairing.HandlePIN(sess.deviceID, p.PIN)
	if ok {
		sess.authed = true
		log.Printf("transport: authed via PIN device=%q", sess.deviceName)
		if s.onAuth != nil {
			go s.onAuth()
		}
	} else {
		log.Printf("transport: PIN check failed device=%q code=%s", sess.deviceName, code)
	}
	s.publishStatus()
	sendJSON(sess, protocol.Message{
		V: protocol.Version, Type: protocol.TypePairResult,
		Data: mustMarshal(protocol.PairResultPayload{OK: ok, Token: token, Code: code, NeedPIN: !ok && code != "locked"}),
	})
	s.ack(sess, msg.ID, true, "")
}

func (s *Server) ack(sess *session, refID string, ok bool, errStr string) {
	sendJSON(sess, protocol.Message{
		V: protocol.Version, Type: protocol.TypeAck,
		Data: mustMarshal(protocol.AckPayload{RefID: refID, OK: ok, Error: errStr}),
	})
}

func sendJSON(sess *session, m protocol.Message) {
	sess.writeMu.Lock()
	defer sess.writeMu.Unlock()
	_ = sess.conn.WriteJSON(m)
}

// dropSession removes one client. Pairing is reset only once the LAST client
// leaves, so one of (app, IME) disconnecting doesn't wipe a pairing in progress
// for the other.
func (s *Server) dropSession(sess *session, reason string) {
	s.mu.Lock()
	_, existed := s.sessions[sess]
	delete(s.sessions, sess)
	remaining := len(s.sessions)
	s.mu.Unlock()
	if existed {
		dur := time.Since(sess.connectedAt).Truncate(time.Second)
		log.Printf("transport: session closed device=%q reason=%s lasted=%s",
			sess.deviceName, reason, dur)
		_ = sess.conn.Close()
	}
	if remaining == 0 && s.pairing != nil {
		s.pairing.Reset()
	}
	s.publishStatus()
}

// closeAllSessions tears down every client (used on server stop).
func (s *Server) closeAllSessions(reason string) {
	s.mu.Lock()
	all := make([]*session, 0, len(s.sessions))
	for sess := range s.sessions {
		all = append(all, sess)
	}
	s.sessions = map[*session]struct{}{}
	s.mu.Unlock()
	for _, sess := range all {
		log.Printf("transport: session closed device=%q reason=%s", sess.deviceName, reason)
		_ = sess.conn.Close()
	}
	if s.pairing != nil {
		s.pairing.Reset()
	}
	s.publishStatus()
}

// snapshotSessions copies the live session set so callers can iterate without
// holding the lock during (blocking) socket writes.
func (s *Server) snapshotSessions() []*session {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*session, 0, len(s.sessions))
	for sess := range s.sessions {
		out = append(out, sess)
	}
	return out
}

func (s *Server) publishStatus() {
	if s.bus == nil {
		return
	}
	s.bus.Publish("transport:status", s.Status())
}

func mustMarshal(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// LANIPv4s returns all non-loopback IPv4 addresses of this host, so the UI can
// show users where to point the mobile app when discovery fails.
func LANIPv4s() []string {
	out := []string{}
	ifaces, err := net.Interfaces()
	if err != nil {
		return out
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			ip = ip.To4()
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}
			out = append(out, ip.String())
		}
	}
	return out
}

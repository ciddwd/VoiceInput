import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../protocol/messages.dart';
import 'token_store.dart';

enum WsState { disconnected, connecting, awaitingPin, authed, locked }

class PairingError {
  final String code;
  final String message;
  PairingError(this.code, this.message);
  @override
  String toString() => '$code: $message';
}

class WsClient {
  final TokenStore tokens;
  final String deviceName;

  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;

  final _stateCtrl = StreamController<WsState>.broadcast();
  final _msgCtrl = StreamController<Envelope>.broadcast();
  final _errorCtrl = StreamController<PairingError>.broadcast();

  WsState _state = WsState.disconnected;
  String? _currentHost;
  int? _currentPort;

  // Auto-reconnect state. Once a session reaches `authed`, we treat the next
  // unexpected close as a transient blip and retry with backoff. Surrendering
  // here is preferable to silently disconnecting the user mid-dictation.
  bool _wasAuthed = false;
  // Set when the server tells us another device/instance took over this peer.
  // We then stand down instead of auto-reconnecting — otherwise two clients
  // sharing one deviceId ping-pong the session forever (the "paired status
  // flaps once a second" bug). Cleared on the next user-initiated connect.
  bool _displaced = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  // Optional hook the UI installs so each reconnect re-targets the freshest
  // known address (newest discovery hit, else the active device, else the
  // stored last peer) instead of being stuck on the address first dialed.
  // This is what makes reconnects follow the desktop across an IP change
  // (DHCP renew, Wi-Fi roam) and pick whichever transport (mDNS/UDP) is live.
  ({String host, int port})? Function()? peerResolver;

  WsClient({required this.tokens, this.deviceName = 'Mobile'});

  WsState get state => _state;
  Stream<WsState> get states => _stateCtrl.stream;
  Stream<Envelope> get messages => _msgCtrl.stream;
  Stream<PairingError> get errors => _errorCtrl.stream;

  Future<void> connect(String host, int port) async {
    _log('connect host=$host port=$port');
    await disconnect(intentional: true);
    // A fresh user-initiated connect clears any prior "displaced" standdown.
    _displaced = false;
    _setState(WsState.connecting);
    _currentHost = host;
    _currentPort = port;
    try {
      final uri = Uri.parse('ws://$host:$port/ws');
      _channel = IOWebSocketChannel.connect(uri, pingInterval: const Duration(seconds: 20));
      _sub = _channel!.stream.listen(
        _onRaw,
        onError: (e) {
          _log('socket error: $e');
          _onClosed();
        },
        onDone: () {
          _log('socket done (close code=${_channel?.closeCode}, reason=${_channel?.closeReason})');
          _onClosed();
        },
        cancelOnError: true,
      );
      // Fire the hello as soon as the socket is open. If we have a stored
      // token for this host, ride straight into Authed; otherwise the server
      // will respond with NeedPIN.
      final token = tokens.tokenFor(host, port);
      final hello = <String, dynamic>{
        'deviceId': tokens.deviceId,
        'deviceName': deviceName,
      };
      if (token != null) hello['token'] = token;
      _send(Envelope(type: MsgType.hello, data: hello));
    } catch (e) {
      _log('connect threw: $e');
      _setState(WsState.disconnected);
      rethrow;
    }
  }

  /// Submits a PIN to finish the pairing handshake.
  void submitPin(String pin) {
    if (_state != WsState.awaitingPin) return;
    _send(Envelope(type: MsgType.pairPin, data: {'pin': pin}));
  }

  /// Sends a business payload (text/input, text/clear). No-ops unless authed.
  void send(Envelope env) {
    if (_state != WsState.authed) return;
    _send(env);
  }

  Future<void> disconnect({bool intentional = true}) async {
    if (intentional) {
      _wasAuthed = false;
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    await _sub?.cancel();
    _sub = null;
    if (_channel != null) {
      await _channel!.sink.close(ws_status.normalClosure);
      _channel = null;
    }
    if (intentional) {
      _currentHost = null;
      _currentPort = null;
    }
    _setState(WsState.disconnected);
  }

  void _send(Envelope env) {
    if (_channel == null) return;
    _channel!.sink.add(env.encode());
  }

  void _onRaw(dynamic raw) {
    final Envelope env;
    try {
      env = Envelope.decode(raw as String);
    } catch (_) {
      return;
    }

    if (env.type == MsgType.error) {
      final d = env.data ?? const {};
      final code = d['code']?.toString() ?? '';
      _log('server error: $code / ${d['message']}');
      if (code == 'displaced') {
        // Another device/instance grabbed this desktop. Reconnecting would
        // kick *them* off and restart a mutual-displacement loop that shows
        // up as the pairing status flapping once a second. Stand down.
        _displaced = true;
        _wasAuthed = false;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _errorCtrl.add(PairingError('displaced', d['message']?.toString() ?? 'Taken over by another device'));
      }
      return;
    }

    if (env.type == MsgType.pairResult) {
      final d = env.data ?? const {};
      final ok = d['ok'] == true;
      final needPin = d['needPin'] == true;
      final token = d['token'] as String?;
      final code = d['code'] as String?;
      if (ok) {
        if (_currentHost != null && _currentPort != null) {
          if (token != null && token.isNotEmpty) {
            tokens.save(_currentHost!, _currentPort!, token);
          }
          tokens.setLastPeer(_currentHost!, _currentPort!);
        }
        _wasAuthed = true;
        _reconnectAttempts = 0;
        _setState(WsState.authed);
        _log('authed');
      } else if (code == 'locked') {
        _setState(WsState.locked);
        _errorCtrl.add(PairingError('locked', 'Too many wrong PINs; device locked for 60 s.'));
      } else if (needPin) {
        _setState(WsState.awaitingPin);
        if (code == 'invalid_pin') {
          _errorCtrl.add(PairingError('invalid_pin', 'Wrong PIN, try again.'));
        } else if (code == 'bad_token') {
          if (_currentHost != null && _currentPort != null) {
            tokens.forget(_currentHost!, _currentPort!);
          }
        }
      } else if (code != null) {
        _errorCtrl.add(PairingError(code, code));
      }
      return;
    }

    _msgCtrl.add(env);
  }

  void _onClosed() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    final host = _currentHost;
    final port = _currentPort;
    _setState(WsState.disconnected);

    // If we were authed and the user hasn't explicitly disconnected, try a few
    // automatic reconnects. Common causes covered:
    //   - server's "latest-wins" temporarily kicked us;
    //   - Wi-Fi roamed / momentarily dropped;
    //   - desktop process briefly restarted.
    if (_wasAuthed && !_displaced && host != null && port != null) {
      _reconnectAttempts++;
      // Exponential backoff capped at 8s, retried indefinitely: a brief outage
      // (Wi-Fi roam, desktop restart) should recover on its own rather than
      // giving up after a few tries and stranding the user mid-dictation.
      final step = _reconnectAttempts.clamp(1, 5);
      final delayMs = (400 * (1 << step)).clamp(800, 8000);
      _log('reconnect scheduled #$_reconnectAttempts in ${delayMs}ms');
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
        if (_state != WsState.disconnected) return;
        // Re-target to the freshest known address if the UI gave us a resolver,
        // so we follow the desktop if its IP changed while we were down.
        final p = peerResolver?.call();
        connect(p?.host ?? host, p?.port ?? port).catchError((e) {
          _log('reconnect attempt failed: $e');
        });
      });
    } else {
      _wasAuthed = false;
      _reconnectAttempts = 0;
    }
  }

  void _setState(WsState s) {
    if (_state == s) return;
    _log('state: $_state -> $s');
    _state = s;
    _stateCtrl.add(s);
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[WsClient] $msg');
  }

  void dispose() {
    _reconnectTimer?.cancel();
    disconnect(intentional: true);
    _stateCtrl.close();
    _msgCtrl.close();
    _errorCtrl.close();
  }
}

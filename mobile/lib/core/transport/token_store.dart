import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Persists the per-desktop pairing tokens issued by the receiver, plus this
/// device's stable ID. Storage is shared_preferences keyed under one JSON blob,
/// which keeps the disk footprint small and migration trivial.
class TokenStore {
  static const _kBlob = 'voiceinput.tokens.v1';
  static const _kDeviceId = 'voiceinput.deviceId';
  static const _kLastPeer = 'voiceinput.lastPeer'; // "host:port"

  final SharedPreferences _prefs;
  final Map<String, String> _tokens; // peerKey ("host:port") -> token
  final String _deviceId;

  TokenStore._(this._prefs, this._tokens, this._deviceId);

  static Future<TokenStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, String> tokens = {};
    final raw = prefs.getString(_kBlob);
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        tokens = m.map((k, v) => MapEntry(k, v as String));
      } catch (_) {
        tokens = {};
      }
    }
    var id = prefs.getString(_kDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_kDeviceId, id);
    }
    return TokenStore._(prefs, tokens, id);
  }

  String get deviceId => _deviceId;

  String? tokenFor(String host, int port) => _tokens['$host:$port'];

  /// Most recent successful peer ("host:port"), or null if never paired.
  /// The main app writes this on connect so the IME can auto-reconnect.
  PeerEndpoint? get lastPeer {
    final raw = _prefs.getString(_kLastPeer);
    if (raw == null || raw.isEmpty) return null;
    final i = raw.lastIndexOf(':');
    if (i <= 0) return null;
    final host = raw.substring(0, i);
    final port = int.tryParse(raw.substring(i + 1));
    if (port == null) return null;
    return PeerEndpoint(host: host, port: port);
  }

  Future<void> setLastPeer(String host, int port) =>
      _prefs.setString(_kLastPeer, '$host:$port');

  Future<void> save(String host, int port, String token) async {
    _tokens['$host:$port'] = token;
    await _flush();
  }

  Future<void> forget(String host, int port) async {
    _tokens.remove('$host:$port');
    await _flush();
  }

  Future<void> forgetAll() async {
    _tokens.clear();
    await _flush();
  }

  Future<void> _flush() async {
    await _prefs.setString(_kBlob, jsonEncode(_tokens));
  }
}

class PeerEndpoint {
  final String host;
  final int port;
  const PeerEndpoint({required this.host, required this.port});
}

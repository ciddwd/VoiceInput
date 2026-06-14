// Mirror of desktop/internal/protocol/messages.go — keep field names in sync.
import 'dart:convert';
import 'package:uuid/uuid.dart';

const int protocolVersion = 1;

class MsgType {
  static const hello = 'hello';
  static const pairPin = 'pair/pin';
  static const pairResult = 'pair/result';
  static const auth = 'auth';
  static const textInput = 'text/input';
  static const textClear = 'text/clear';
  static const focusUpdate = 'focus/update';
  static const snippetsSnapshot = 'snippets/snapshot';
  static const snippetsDelta = 'snippets/delta';
  static const heartbeat = 'heartbeat';
  static const ack = 'ack';
  static const error = 'error';
}

class Envelope {
  final int v;
  final String id;
  final String type;
  final Map<String, dynamic>? data;

  Envelope({required this.type, this.data, String? id, this.v = protocolVersion})
      : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
        'v': v,
        'id': id,
        'type': type,
        if (data != null) 'data': data,
      };

  String encode() => jsonEncode(toJson());

  static Envelope decode(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return Envelope(
      v: (m['v'] as int?) ?? protocolVersion,
      id: m['id'] as String? ?? '',
      type: m['type'] as String,
      data: (m['data'] as Map?)?.cast<String, dynamic>(),
    );
  }
}

// Polish layer: rewrite raw ASR text before it leaves the phone.
//
// Lives entirely on the mobile side: the API key, the provider config, and
// the HTTP request all happen here. The desktop just receives the polished
// (or raw) string and injects it. This keeps the desktop a pure receiver and
// lets the user review the polished text in the buffer before sending.

import 'dart:async';

// `command` is the voice-correction mode used by the IME: instead of rewriting
// the whole utterance, the model applies one spoken edit instruction to an
// existing text. It carries an extra [PolishRequest.instruction] payload.
enum PolishMode { raw, light, structured, formal, command }

extension PolishModeX on PolishMode {
  String get wire {
    switch (this) {
      case PolishMode.raw:        return 'raw';
      case PolishMode.light:      return 'light';
      case PolishMode.structured: return 'structured';
      case PolishMode.formal:     return 'formal';
      case PolishMode.command:    return 'command';
    }
  }

  String get label {
    switch (this) {
      case PolishMode.raw:        return 'Raw';
      case PolishMode.light:      return 'Light';
      case PolishMode.structured: return 'Structured';
      case PolishMode.formal:     return 'Formal';
      case PolishMode.command:    return 'Command';
    }
  }

  static PolishMode fromWire(String? s) {
    switch (s) {
      case 'light':      return PolishMode.light;
      case 'structured': return PolishMode.structured;
      case 'formal':     return PolishMode.formal;
      case 'command':    return PolishMode.command;
      default:           return PolishMode.raw;
    }
  }
}

class PolishRequest {
  final PolishMode mode;
  final String text;
  final String locale;
  final List<String> hotwords;
  // Spoken edit instruction for [PolishMode.command] (e.g. "把今天换成明天").
  // Null/ignored for the rewrite modes.
  final String? instruction;
  const PolishRequest({
    required this.mode,
    required this.text,
    this.locale = 'zh',
    this.hotwords = const [],
    this.instruction,
  });
}

class PolishResult {
  final String text;
  final String model;
  final String provider;
  const PolishResult({required this.text, required this.model, required this.provider});
}

class PolishException implements Exception {
  final String message;
  const PolishException(this.message);
  @override
  String toString() => 'PolishException: $message';
}

abstract class PolishProvider {
  String get name;
  Future<PolishResult> polish(PolishRequest req);
}

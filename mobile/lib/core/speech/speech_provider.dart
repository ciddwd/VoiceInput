// Pluggable ASR contract. The IME UI binds to this rather than speech_to_text
// directly, so phase 2+ can swap in cloud streaming providers.
import 'dart:async';

enum SpeechEventKind { partial, finalResult, done, error }

class SpeechEvent {
  final SpeechEventKind kind;
  final String text;
  final String? errorCode;
  const SpeechEvent.partial(this.text) : kind = SpeechEventKind.partial, errorCode = null;
  const SpeechEvent.finalResult(this.text) : kind = SpeechEventKind.finalResult, errorCode = null;
  /// Engine reports it has stopped listening, regardless of whether a final
  /// result was delivered. UI uses this to leave the "listening" state even
  /// when the underlying ASR was silent.
  const SpeechEvent.done() : kind = SpeechEventKind.done, text = '', errorCode = null;
  const SpeechEvent.error(this.errorCode) : kind = SpeechEventKind.error, text = '';
}

abstract class SpeechProvider {
  /// Returns whether the provider is available on this device (permissions
  /// granted + service installed). Call before `start`.
  Future<bool> initialize();

  /// Last initialisation error in human-readable form, if any. Useful for
  /// surfacing OEM-specific blockers (e.g. Xiaomi mibrain.speech denied).
  String? get lastError;

  /// Begin recognition. The returned stream emits partial results as the user
  /// speaks, plus one finalResult when ASR concludes (silence / explicit stop).
  Stream<SpeechEvent> start({String locale = 'zh_CN'});

  Future<void> stop();
  Future<void> cancel();
  bool get isListening;
}

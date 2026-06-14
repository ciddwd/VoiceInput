import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'speech_provider.dart';

/// SpeechProvider backed by the device's system STT via the speech_to_text
/// package. Works offline on devices with Google's on-device model installed,
/// otherwise falls back to network recognition.
///
/// Long-utterance handling: Android's SpeechRecognizer terminates a single
/// recognition stream after a vendor-defined limit (10–60 s depending on
/// device / engine). Past that boundary the engine emits either
/// `error_network_timeout` or `status=done`, and the buffer the user has
/// already accumulated is lost. To make long dictation feel continuous, this
/// provider treats every "session end" that the user did NOT explicitly
/// trigger as a *sub-session boundary*: it folds whatever was recognised so
/// far into a per-call accumulator and silently restarts the engine. Partials
/// keep flowing to the UI as `accumulator + currentSubSession.partial`, so the
/// UI sees one uninterrupted stream and the safety watchdog upstream stays
/// reset.
class SystemSpeechProvider implements SpeechProvider {
  final stt.SpeechToText _engine = stt.SpeechToText();
  StreamController<SpeechEvent>? _ctrl;
  bool _initialized = false;
  String? _lastError;

  // Accumulator of all confirmed text from prior sub-sessions in the current
  // user-facing listening session. New partials are emitted as
  // `_sessionAccum + _lastPartial` so the UI always sees the full stream.
  String _sessionAccum = '';
  // Most recent partial from the *current* sub-session (the engine instance
  // that is live right now). Rolled into _sessionAccum whenever a sub-session
  // ends so we never lose it across the engine restart.
  String _lastPartial = '';
  // True once stop() has been called by the caller — i.e. the user pressed the
  // mic button to stop dictation. Distinguishes a real "session end" from a
  // sub-session boundary that we should silently bridge.
  bool _userStopped = false;
  // Whether we've already scheduled a sub-session restart; prevents a flurry
  // of done+error+timeout signals from queueing up multiple restarts.
  bool _restartScheduled = false;
  // Have we emitted the terminal finalResult for this session? Set both when
  // stop() drains the accumulator and when a hard error gives up.
  bool _finalEmitted = false;
  // Track session locale across sub-session restarts.
  String _currentLocale = 'zh_CN';
  // Did the current sub-session ever produce a partial? If a restart yields
  // zero partials it's likely a hard failure (no mic, denied permission mid-
  // flight, engine wedged) — after a few of these in a row we bail instead
  // of looping forever.
  bool _gotPartialThisSubSession = false;
  int _consecutiveSilentSubSessions = 0;
  static const int _maxSilentSubSessions = 3;
  // Guards against emitting the terminal `done` more than once when both
  // onStatus 'done' and a subsequent onError fire after the user stopped.
  bool _doneEmitted = false;
  // Timestamp of the most recent engine-level final. Because we now restart
  // proactively from onResult(finalResult), the engine's own subsequent
  // status='done' for that same sub-session arrives ~hundreds of ms later
  // and must not trigger a *second* restart on the already-running new
  // sub-session — that would kill the live capture.
  DateTime? _lastFinalAt;
  // Once cancel() is called, the plugin channel can still deliver pending
  // events to our onStatus/onError closures (the speech_to_text plugin
  // shares one channel across SpeechToText instances, so callbacks from a
  // discarded provider keep firing). This flag short-circuits those late
  // events instead of letting them mutate shared state on the new provider.
  bool _disposed = false;

  @override
  String? get lastError => _lastError;

  @override
  Future<bool> initialize() async {
    if (_initialized && _engine.isAvailable) return true;
    try {
      _initialized = await _engine.initialize(
        onError: _onEngineError,
        onStatus: _onEngineStatus,
        debugLogging: true,
      );
      if (!_initialized) {
        _lastError ??=
            'SpeechRecognizer unavailable. Check that a system speech engine is installed and authorized.';
      } else {
        _lastError = null;
      }
    } catch (e) {
      _initialized = false;
      _lastError = e.toString();
    }
    return _initialized;
  }

  @override
  Stream<SpeechEvent> start({String locale = 'zh_CN'}) {
    _ctrl?.close();
    final ctrl = StreamController<SpeechEvent>.broadcast();
    _ctrl = ctrl;
    _sessionAccum = '';
    _lastPartial = '';
    _userStopped = false;
    _restartScheduled = false;
    _finalEmitted = false;
    _gotPartialThisSubSession = false;
    _consecutiveSilentSubSessions = 0;
    _doneEmitted = false;
    _lastFinalAt = null;
    _disposed = false;
    _currentLocale = locale;
    _startListen(ctrl, locale);
    return ctrl.stream;
  }

  void _onEngineStatus(String status) {
    if (_disposed) return;
    debugPrint('[SystemASR] status=$status');
    if (status == 'listening') {
      // Sub-session is live; clear the per-sub-session partial flag so a
      // silent sub-session can be detected.
      _gotPartialThisSubSession = false;
      return;
    }
    if (status == 'done' || status == 'doneNoResult') {
      final ctrl = _ctrl;
      if (ctrl == null || ctrl.isClosed) return;
      if (_userStopped) {
        _emitTerminalFinal(ctrl);
        return;
      }
      // If we just restarted from an onResult(final), this 'done' belongs to
      // the *previous* sub-session and the next one is already live — don't
      // schedule another restart on top of it.
      if (_lastFinalAt != null &&
          DateTime.now().difference(_lastFinalAt!) < const Duration(milliseconds: 1500)) {
        debugPrint('[SystemASR] stale done ignored (recent final-driven restart)');
        return;
      }
      _foldPartialIntoAccum();
      _scheduleRestart(ctrl);
    }
  }

  void _onEngineError(dynamic e) {
    if (_disposed) return;
    final String msg = e.errorMsg;
    debugPrint('[SystemASR] error msg=$msg permanent=${e.permanent}');
    _lastError = msg;
    final ctrl = _ctrl;
    if (ctrl == null || ctrl.isClosed) return;
    if (_userStopped) {
      // User wants to stop; treat any error as terminal but still drain
      // whatever we did capture before propagating.
      _emitTerminalFinal(ctrl);
      return;
    }
    if (_isRecoverable(msg)) {
      _foldPartialIntoAccum();
      _scheduleRestart(ctrl);
      return;
    }
    // Hard error: deliver what we have, then surface the error.
    if (!_finalEmitted) {
      final all = _joinAccum(_sessionAccum, _lastPartial);
      if (all.isNotEmpty) {
        ctrl.add(SpeechEvent.finalResult(all));
        _finalEmitted = true;
      }
    }
    ctrl.add(SpeechEvent.error(msg));
  }

  bool _isRecoverable(String msg) {
    // Anything that essentially means "this sub-session ended, try again" —
    // the network/busy/timeout family from Google's recognizer and MIUI's
    // mibrain.speech equivalents.
    return msg.contains('error_network_timeout') ||
        msg.contains('error_network') ||
        msg.contains('error_busy') ||
        msg.contains('error_client') ||
        msg.contains('error_no_match') ||
        msg.contains('error_speech_timeout');
  }

  void _foldPartialIntoAccum() {
    if (_lastPartial.isEmpty) return;
    _sessionAccum = _joinAccum(_sessionAccum, _lastPartial);
    _lastPartial = '';
  }

  void _emitTerminalFinal(StreamController<SpeechEvent> ctrl) {
    if (_doneEmitted) return;
    _doneEmitted = true;
    final all = _joinAccum(_sessionAccum, _lastPartial);
    if (!_finalEmitted && all.isNotEmpty) {
      ctrl.add(SpeechEvent.finalResult(all));
      _finalEmitted = true;
    }
    ctrl.add(const SpeechEvent.done());
  }

  void _scheduleRestart(StreamController<SpeechEvent> ctrl) {
    if (_restartScheduled) return;
    if (!_gotPartialThisSubSession) {
      _consecutiveSilentSubSessions++;
      if (_consecutiveSilentSubSessions >= _maxSilentSubSessions) {
        debugPrint('[SystemASR] giving up after $_consecutiveSilentSubSessions silent sub-sessions');
        _emitTerminalFinal(ctrl);
        return;
      }
    } else {
      _consecutiveSilentSubSessions = 0;
    }
    _restartScheduled = true;
    debugPrint('[SystemASR] auto-restart sub-session accumLen=${_sessionAccum.length}');
    // Push the restart to a fresh microtask so the onResult/onStatus
    // callback returns first (re-entering plugin code from inside its own
    // callback has caused error_busy on some ROMs). 30 ms is a tiny tail
    // beyond that, just to let speech_to_text fully unwind its current
    // dispatch before we ask it for a new session.
    Future.delayed(const Duration(milliseconds: 30), () {
      _restartScheduled = false;
      final c = _ctrl;
      if (c == null || c.isClosed) return;
      if (_userStopped) return;
      _startListen(c, _currentLocale);
    });
  }

  Future<void> _startListen(
      StreamController<SpeechEvent> ctrl, String locale) async {
    debugPrint('[SystemASR] startListen locale=$locale wasListening=${_engine.isListening}');
    if (_engine.isListening) {
      // Don't wait — the previous sub-session is already in its tear-down
      // path (we're here because either it emitted final or status went to
      // done/error). speech_to_text's listen() rejects if a session is
      // still fully active, so we cancel first, but the 200 ms grace period
      // the old code waited was just dead air, dropping mid-sentence audio.
      await _engine.cancel();
    }
    _gotPartialThisSubSession = false;
    _lastPartial = '';
    _engine.listen(
      listenOptions: stt.SpeechListenOptions(
        listenFor: const Duration(seconds: 120),
        pauseFor: const Duration(seconds: 30),
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        localeId: locale,
      ),
      onResult: (r) {
        if (_disposed) return;
        final words = r.recognizedWords;
        debugPrint('[SystemASR] onResult final=${r.finalResult} words="$words"');
        if (ctrl.isClosed) return;
        if (words.isNotEmpty) _gotPartialThisSubSession = true;
        if (r.finalResult) {
          // Engine-level "final" here ends a sub-session, not the user's
          // utterance. Critically, MIUI mibrain stops processing new audio
          // after emitting final even though `status` stays at "listening" —
          // we have to proactively tear down and restart the sub-session to
          // keep capturing, rather than waiting for the engine's own done
          // (which can be tens of seconds away when listenFor is 120 s).
          if (words.isNotEmpty) {
            _sessionAccum = _joinAccum(_sessionAccum, words);
            _lastPartial = '';
            ctrl.add(SpeechEvent.partial(_sessionAccum));
          }
          if (!_userStopped) {
            _lastFinalAt = DateTime.now();
            _scheduleRestart(ctrl);
          }
        } else {
          _lastPartial = words;
          ctrl.add(SpeechEvent.partial(_joinAccum(_sessionAccum, _lastPartial)));
        }
      },
    );
  }

  @override
  Future<void> stop() async {
    _userStopped = true;
    await _engine.stop();
    // Don't synthesise a final here; let onStatus done deliver it via
    // _emitTerminalFinal so a late onResult (MIUI mibrain delivers up to ~1 s
    // after stop) still gets a chance to land before we close out.
  }

  @override
  Future<void> cancel() async {
    _disposed = true;
    _userStopped = true;
    try { await _engine.cancel(); } catch (_) {}
    await _ctrl?.close();
    _ctrl = null;
  }

  @override
  bool get isListening => _engine.isListening;

  // Join two text fragments across a sub-session boundary, inserting a single
  // ASCII space when needed so consecutive English words don't fuse. Mirrors
  // the boundary logic in voice_keyboard_page._joinSegment.
  static String _joinAccum(String prev, String next) {
    if (prev.isEmpty) return next;
    if (next.isEmpty) return prev;
    final last = prev.codeUnitAt(prev.length - 1);
    if (last == 0x20 || last == 0x09 || last == 0x0A || last == 0x0D) {
      return prev + next;
    }
    const punct = {
      0x2C, 0x2E, 0x21, 0x3F, 0x3B, 0x3A,
      0x3001, 0x3002, 0xFF0C, 0xFF1F, 0xFF01, 0xFF1B, 0xFF1A,
      0x2026, 0x2014,
    };
    if (punct.contains(last)) return prev + next;
    final first = next.codeUnitAt(0);
    if (_isCjkCode(last) || _isCjkCode(first)) return prev + next;
    return '$prev $next';
  }

  static bool _isCjkCode(int c) {
    return (c >= 0x4E00 && c <= 0x9FFF) ||
        (c >= 0x3400 && c <= 0x4DBF) ||
        (c >= 0x3040 && c <= 0x30FF) ||
        (c >= 0xAC00 && c <= 0xD7AF);
  }
}

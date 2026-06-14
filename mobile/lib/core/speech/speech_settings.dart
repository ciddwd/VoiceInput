import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'speech_provider.dart';
import 'system_speech_provider.dart';
import 'volcengine_speech_provider.dart';
import 'whisper_speech_provider.dart';

/// Which ASR engine the user has picked. The "system" option is the
/// on-device / OEM speech engine via the speech_to_text plugin — works
/// offline on capable devices and is the default. "whisper" hits any
/// /v1/audio/transcriptions endpoint. "volcengine" is reserved for the
/// streaming WS implementation (currently a stub).
enum SpeechEngineKind { system, whisper, volcengine }

/// How the mic button arms a recording.
///   tap  — tap once to start, tap again to stop (the original behaviour).
///   hold — press and hold to record, release to stop (walkie-talkie style).
enum MicTriggerMode { tap, hold }

extension MicTriggerModeX on MicTriggerMode {
  String get wire => this == MicTriggerMode.hold ? 'hold' : 'tap';

  static MicTriggerMode fromWire(String? s) =>
      s == 'hold' ? MicTriggerMode.hold : MicTriggerMode.tap;
}

extension SpeechEngineKindX on SpeechEngineKind {
  String get wire {
    switch (this) {
      case SpeechEngineKind.system:     return 'system';
      case SpeechEngineKind.whisper:    return 'whisper';
      case SpeechEngineKind.volcengine: return 'volcengine';
    }
  }

  String get label {
    switch (this) {
      case SpeechEngineKind.system:     return 'System (offline / OEM)';
      case SpeechEngineKind.whisper:    return 'Whisper compatible (batch)';
      case SpeechEngineKind.volcengine: return 'Volcengine streaming (preview)';
    }
  }

  static SpeechEngineKind fromWire(String? s) {
    switch (s) {
      case 'whisper':    return SpeechEngineKind.whisper;
      case 'volcengine': return SpeechEngineKind.volcengine;
      default:           return SpeechEngineKind.system;
    }
  }
}

class SpeechSettings {
  SpeechEngineKind engine;
  // How the mic button triggers recording (tap-to-toggle vs hold-to-talk).
  MicTriggerMode micMode;
  // Whisper
  String whisperBaseUrl;
  String whisperApiKey;
  String whisperModel;
  String whisperLanguage;
  // Volcengine streaming
  String vcAppId;
  String vcAccessKey;
  String vcResourceId; // "volc.bigasr.sauc.duration" / "volc.bigasr.sauc.bigmodel"
  String vcEndpoint;   // override if user uses an enterprise mirror
  String vcLanguage;

  SpeechSettings({
    this.engine = SpeechEngineKind.system,
    this.micMode = MicTriggerMode.tap,
    this.whisperBaseUrl = 'https://api.openai.com/v1',
    this.whisperApiKey = '',
    this.whisperModel = 'whisper-1',
    this.whisperLanguage = 'zh',
    this.vcAppId = '',
    this.vcAccessKey = '',
    this.vcResourceId = 'volc.bigasr.sauc.duration',
    this.vcEndpoint = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
    this.vcLanguage = 'zh-CN',
  });

  factory SpeechSettings.fromJson(Map<String, dynamic> j) => SpeechSettings(
        engine: SpeechEngineKindX.fromWire(j['engine'] as String?),
        micMode: MicTriggerModeX.fromWire(j['micMode'] as String?),
        whisperBaseUrl: j['whisperBaseUrl'] as String? ?? 'https://api.openai.com/v1',
        whisperApiKey: j['whisperApiKey'] as String? ?? '',
        whisperModel: j['whisperModel'] as String? ?? 'whisper-1',
        whisperLanguage: j['whisperLanguage'] as String? ?? 'zh',
        vcAppId: j['vcAppId'] as String? ?? '',
        vcAccessKey: j['vcAccessKey'] as String? ?? '',
        vcResourceId: j['vcResourceId'] as String? ?? 'volc.bigasr.sauc.duration',
        vcEndpoint: j['vcEndpoint'] as String? ?? 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
        vcLanguage: j['vcLanguage'] as String? ?? 'zh-CN',
      );

  Map<String, dynamic> toJson() => {
        'engine': engine.wire,
        'micMode': micMode.wire,
        'whisperBaseUrl': whisperBaseUrl,
        'whisperApiKey': whisperApiKey,
        'whisperModel': whisperModel,
        'whisperLanguage': whisperLanguage,
        'vcAppId': vcAppId,
        'vcAccessKey': vcAccessKey,
        'vcResourceId': vcResourceId,
        'vcEndpoint': vcEndpoint,
        'vcLanguage': vcLanguage,
      };

  /// Build a fresh provider instance. [hotwords] is injected into the
  /// Volcengine config so the model preserves user-curated terms.
  SpeechProvider buildProvider({List<String> hotwords = const []}) {
    switch (engine) {
      case SpeechEngineKind.whisper:
        return WhisperSpeechProvider(
          baseUrl: whisperBaseUrl,
          apiKey: whisperApiKey,
          model: whisperModel,
          language: whisperLanguage,
        );
      case SpeechEngineKind.volcengine:
        return VolcengineSpeechProvider(
          appId: vcAppId,
          accessKey: vcAccessKey,
          resourceId: vcResourceId,
          endpoint: vcEndpoint,
          language: vcLanguage,
          hotwords: hotwords,
        );
      case SpeechEngineKind.system:
        return SystemSpeechProvider();
    }
  }
}

class SpeechSettingsStore {
  static const _kBlob = 'voiceinput.speech.v1';

  final _ctrl = StreamController<SpeechSettings>.broadcast();
  SpeechSettings _current = SpeechSettings();

  SpeechSettings get current => _current;
  Stream<SpeechSettings> get changes => _ctrl.stream;

  Future<void> load({bool fromDisk = false}) async {
    final p = await SharedPreferences.getInstance();
    // The IME runs in a separate Flutter engine/isolate from the main app, so
    // its SharedPreferences cache won't pick up a setting the app saved after
    // this isolate first read it (e.g. switching tap↔hold). reload() forces a
    // fresh read from disk so the IME actually sees the change.
    if (fromDisk) await p.reload();
    final raw = p.getString(_kBlob);
    if (raw == null) return;
    try {
      _current = SpeechSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      _ctrl.add(_current);
    } catch (_) {/* stale */}
  }

  Future<void> save(SpeechSettings s) async {
    _current = s;
    _ctrl.add(s);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBlob, jsonEncode(s.toJson()));
  }

  void dispose() => _ctrl.close();
}

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'anthropic_polish.dart';
import 'openai_polish.dart';
import 'polish.dart';

/// Wire-format identifier for the two real API shapes. Every vendor
/// (DeepSeek/Ark/Moonshot/OpenAI/…) speaks one of these — the difference
/// between them is just base URL + model, kept in [PolishSettings].
enum PolishProtocol { none, openai, anthropic }

extension PolishProtocolX on PolishProtocol {
  String get wire {
    switch (this) {
      case PolishProtocol.openai: return 'openai';
      case PolishProtocol.anthropic: return 'anthropic';
      case PolishProtocol.none: return '';
    }
  }

  static PolishProtocol fromWire(String? s) {
    switch (s) {
      case 'openai':    return PolishProtocol.openai;
      case 'anthropic': return PolishProtocol.anthropic;
      default:          return PolishProtocol.none;
    }
  }
}

/// User-configurable polish settings. Persisted as a single JSON blob in
/// SharedPreferences so loading is one read; mutations rewrite the whole blob.
class PolishSettings {
  PolishProtocol protocol;
  String displayName;
  String baseUrl;
  String apiKey;
  String model;
  Map<PolishMode, String> promptOverrides;
  PolishMode defaultMode;

  PolishSettings({
    this.protocol = PolishProtocol.none,
    this.displayName = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.promptOverrides = const {},
    this.defaultMode = PolishMode.light,
  });

  factory PolishSettings.empty() => PolishSettings();

  factory PolishSettings.fromJson(Map<String, dynamic> j) {
    final overrides = <PolishMode, String>{};
    final raw = (j['promptOverrides'] as Map?)?.cast<String, dynamic>() ?? {};
    raw.forEach((k, v) {
      if (v is String && v.isNotEmpty) {
        overrides[PolishModeX.fromWire(k)] = v;
      }
    });
    return PolishSettings(
      protocol: PolishProtocolX.fromWire(j['protocol'] as String?),
      displayName: j['displayName'] as String? ?? '',
      baseUrl: j['baseUrl'] as String? ?? '',
      apiKey: j['apiKey'] as String? ?? '',
      model: j['model'] as String? ?? '',
      promptOverrides: overrides,
      defaultMode: PolishModeX.fromWire(j['defaultMode'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'protocol': protocol.wire,
        'displayName': displayName,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'promptOverrides': promptOverrides.map((k, v) => MapEntry(k.wire, v)),
        'defaultMode': defaultMode.wire,
      };

  bool get isConfigured =>
      protocol != PolishProtocol.none && apiKey.isNotEmpty && model.isNotEmpty;

  PolishProvider? buildProvider() {
    if (!isConfigured) return null;
    switch (protocol) {
      case PolishProtocol.openai:
        return OpenAIPolishProvider(
          displayName: displayName,
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
          promptOverrides: promptOverrides,
        );
      case PolishProtocol.anthropic:
        return AnthropicPolishProvider(
          baseUrl: baseUrl.isEmpty ? 'https://api.anthropic.com' : baseUrl,
          apiKey: apiKey,
          model: model,
          promptOverrides: promptOverrides,
        );
      case PolishProtocol.none:
        return null;
    }
  }
}

class PolishSettingsStore {
  static const _kBlob = 'voiceinput.polish.v1';

  final _ctrl = StreamController<PolishSettings>.broadcast();
  PolishSettings _current = PolishSettings.empty();

  PolishSettings get current => _current;
  Stream<PolishSettings> get changes => _ctrl.stream;

  Future<void> load({bool fromDisk = false}) async {
    final p = await SharedPreferences.getInstance();
    // The IME runs in a separate Flutter engine/isolate from the main app, so
    // its SharedPreferences cache won't see a provider the app configured after
    // this isolate first read it. reload() forces a fresh read from disk so the
    // IME's correction button doesn't wrongly report "not configured".
    if (fromDisk) await p.reload();
    final raw = p.getString(_kBlob);
    if (raw == null) return;
    try {
      _current = PolishSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      _ctrl.add(_current);
    } catch (_) {/* stale; keep empty */}
  }

  Future<void> save(PolishSettings s) async {
    _current = s;
    _ctrl.add(s);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBlob, jsonEncode(s.toJson()));
  }

  void dispose() => _ctrl.close();
}

/// Vendor presets that just pre-fill base URL + model under one of the two
/// real protocols. Adding a vendor is one line.
class PolishPreset {
  final String label;
  final PolishProtocol protocol;
  final String baseUrl;
  final String model;
  final String? displayName;
  const PolishPreset(this.label, this.protocol, this.baseUrl, this.model, [this.displayName]);
}

const polishPresets = <PolishPreset>[
  PolishPreset('DeepSeek',   PolishProtocol.openai,    'https://api.deepseek.com/v1',                   'deepseek-chat'),
  PolishPreset('OpenAI',     PolishProtocol.openai,    'https://api.openai.com/v1',                     'gpt-4o-mini'),
  PolishPreset('Ark / Doubao', PolishProtocol.openai,  'https://ark.cn-beijing.volces.com/api/v3',      'doubao-1-5-pro-32k-250115', 'Doubao'),
  PolishPreset('Moonshot',   PolishProtocol.openai,    'https://api.moonshot.cn/v1',                    'kimi-k2-0905-preview'),
  PolishPreset('Anthropic',  PolishProtocol.anthropic, 'https://api.anthropic.com',                     'claude-3-5-haiku-latest'),
];

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/polish/polish.dart';
import '../../core/polish/polish_settings.dart';
import '../../core/speech/speech_settings.dart';

/// Phone-side Settings page: configure the polish provider (protocol + key +
/// model), the ASR engine, default polish mode, optional per-mode system
/// prompt overrides, and run a smoke test against a sample sentence.
class SettingsPage extends StatefulWidget {
  final PolishSettingsStore polishStore;
  final SpeechSettingsStore speechStore;
  const SettingsPage({super.key, required this.polishStore, required this.speechStore});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late PolishSettings _draft;
  late SpeechSettings _speechDraft;
  bool _revealKey = false;
  bool _testing = false;
  String? _testOut;
  bool _testOk = false;
  PolishMode _testMode = PolishMode.light;
  final _sampleCtrl = TextEditingController(text: '今天 天气挺不错的 适合 出去走一走');

  @override
  void initState() {
    super.initState();
    _draft = _clone(widget.polishStore.current);
    _speechDraft = _cloneSpeech(widget.speechStore.current);
  }

  SpeechSettings _cloneSpeech(SpeechSettings s) => SpeechSettings(
        engine: s.engine,
        micMode: s.micMode,
        whisperBaseUrl: s.whisperBaseUrl,
        whisperApiKey: s.whisperApiKey,
        whisperModel: s.whisperModel,
        whisperLanguage: s.whisperLanguage,
        vcAppId: s.vcAppId,
        vcAccessKey: s.vcAccessKey,
        vcResourceId: s.vcResourceId,
        vcEndpoint: s.vcEndpoint,
        vcLanguage: s.vcLanguage,
      );

  @override
  void dispose() {
    _sampleCtrl.dispose();
    super.dispose();
  }

  PolishSettings _clone(PolishSettings s) => PolishSettings(
        protocol: s.protocol,
        displayName: s.displayName,
        baseUrl: s.baseUrl,
        apiKey: s.apiKey,
        model: s.model,
        promptOverrides: Map.of(s.promptOverrides),
        defaultMode: s.defaultMode,
      );

  void _applyPreset(PolishPreset preset) {
    setState(() {
      _draft.protocol = preset.protocol;
      _draft.baseUrl = preset.baseUrl;
      _draft.model = preset.model;
      _draft.displayName = preset.displayName ?? preset.label;
    });
  }

  Future<void> _save() async {
    await widget.polishStore.save(_draft);
    await widget.speechStore.save(_speechDraft);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('common.saved')), duration: const Duration(seconds: 1)),
      );
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testOut = null;
    });
    try {
      final provider = _draft.buildProvider();
      if (provider == null) {
        throw const PolishException('Provider not configured');
      }
      final res = await provider.polish(PolishRequest(
        mode: _testMode,
        text: _sampleCtrl.text.trim().isEmpty ? '今天 天气挺不错的' : _sampleCtrl.text,
        locale: 'zh',
      ));
      setState(() {
        _testOk = true;
        _testOut = '[${res.provider} · ${res.model}]\n${res.text}';
      });
    } catch (e) {
      setState(() {
        _testOk = false;
        _testOut = e.toString();
      });
    } finally {
      setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('common.settings')),
        centerTitle: false,
        backgroundColor: cs.surface,
        elevation: 0,
        actions: [
          TextButton(onPressed: _save, child: Text(tr('common.save'))),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _Section(
            title: tr('set.language.label'),
            child: SegmentedButton<AppLocale>(
              segments: [
                ButtonSegment(value: AppLocale.zh, label: Text(tr('set.language.zh'))),
                ButtonSegment(value: AppLocale.en, label: Text(tr('set.language.en'))),
              ],
              selected: {I18n.instance.locale},
              onSelectionChanged: (s) => I18n.instance.setLocale(s.first),
              style: ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: tr('set.micMode'),
            subtitle: tr('set.micModeSub'),
            child: SegmentedButton<MicTriggerMode>(
              segments: [
                ButtonSegment(value: MicTriggerMode.tap, label: Text(tr('set.micTap')), icon: const Icon(Icons.touch_app_outlined, size: 16)),
                ButtonSegment(value: MicTriggerMode.hold, label: Text(tr('set.micHold')), icon: const Icon(Icons.mic_none_outlined, size: 16)),
              ],
              selected: {_speechDraft.micMode},
              onSelectionChanged: (s) => setState(() => _speechDraft.micMode = s.first),
              style: ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: tr('set.speechSection'),
            subtitle: tr('set.speechSub'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<SpeechEngineKind>(
                  initialValue: _speechDraft.engine,
                  isExpanded: true,
                  decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      labelText: tr('set.engine')),
                  items: [
                    DropdownMenuItem(value: SpeechEngineKind.system,     child: Text(tr('set.engineSystem'))),
                    DropdownMenuItem(value: SpeechEngineKind.whisper,    child: Text(tr('set.engineWhisper'))),
                    DropdownMenuItem(value: SpeechEngineKind.volcengine, child: Text(tr('set.engineVolcengine'))),
                  ],
                  onChanged: (v) => setState(() => _speechDraft.engine = v ?? SpeechEngineKind.system),
                ),
                if (_speechDraft.engine == SpeechEngineKind.whisper) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.whisperBaseUrl,
                    decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true, labelText: tr('set.baseUrl'), hintText: 'https://api.openai.com/v1'),
                    onChanged: (v) => _speechDraft.whisperBaseUrl = v,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.whisperModel,
                    decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true, labelText: tr('set.model'), hintText: 'whisper-1'),
                    onChanged: (v) => _speechDraft.whisperModel = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.whisperApiKey,
                    obscureText: !_revealKey,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      labelText: tr('set.apiKey'),
                      suffixIcon: IconButton(
                        icon: Icon(_revealKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                        onPressed: () => setState(() => _revealKey = !_revealKey),
                      ),
                    ),
                    onChanged: (v) => _speechDraft.whisperApiKey = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.whisperLanguage,
                    decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true, labelText: tr('set.language'), hintText: 'zh, en, ja, ko, …'),
                    onChanged: (v) => _speechDraft.whisperLanguage = v,
                    autocorrect: false,
                  ),
                ],
                if (_speechDraft.engine == SpeechEngineKind.volcengine) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.vcAppId,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'App Key (X-Api-App-Key)'),
                    onChanged: (v) => _speechDraft.vcAppId = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.vcAccessKey,
                    obscureText: !_revealKey,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      labelText: 'Access Key (X-Api-Access-Key)',
                      suffixIcon: IconButton(
                        icon: Icon(_revealKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                        onPressed: () => setState(() => _revealKey = !_revealKey),
                      ),
                    ),
                    onChanged: (v) => _speechDraft.vcAccessKey = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _speechDraft.vcResourceId,
                    isExpanded: true,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Resource ID'),
                    items: const [
                      DropdownMenuItem(value: 'volc.bigasr.sauc.duration', child: Text('volc.bigasr.sauc.duration  (Doubao 1.0 · 小时版)')),
                      DropdownMenuItem(value: 'volc.bigasr.sauc.concurrent', child: Text('volc.bigasr.sauc.concurrent  (Doubao 1.0 · 并发版)')),
                      DropdownMenuItem(value: 'volc.seedasr.sauc.duration', child: Text('volc.seedasr.sauc.duration  (Doubao 2.0 · 小时版)')),
                      DropdownMenuItem(value: 'volc.seedasr.sauc.concurrent', child: Text('volc.seedasr.sauc.concurrent  (Doubao 2.0 · 并发版)')),
                    ],
                    onChanged: (v) => setState(() => _speechDraft.vcResourceId = v ?? 'volc.bigasr.sauc.duration'),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.vcLanguage,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Language', hintText: 'zh-CN, en-US, …'),
                    onChanged: (v) => _speechDraft.vcLanguage = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.vcEndpoint,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Endpoint (override only if needed)'),
                    onChanged: (v) => _speechDraft.vcEndpoint = v,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('set.vcHint'),
                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: tr('set.polishSection'),
            subtitle: tr('set.polishSub'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _label(tr('set.presets')),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in polishPresets)
                      ActionChip(
                        label: Text(preset.label),
                        onPressed: () => _applyPreset(preset),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _label(tr('set.protocol')),
                const SizedBox(height: 4),
                DropdownButtonFormField<PolishProtocol>(
                  initialValue: _draft.protocol,
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  items: [
                    DropdownMenuItem(value: PolishProtocol.none,      child: Text(tr('set.protoNone'))),
                    DropdownMenuItem(value: PolishProtocol.openai,    child: Text(tr('set.protoOpenAI'))),
                    DropdownMenuItem(value: PolishProtocol.anthropic, child: Text(tr('set.protoAnthropic'))),
                  ],
                  onChanged: (v) => setState(() => _draft.protocol = v ?? PolishProtocol.none),
                ),
                const SizedBox(height: 10),
                _label(tr('set.displayName')),
                const SizedBox(height: 4),
                TextFormField(
                  initialValue: _draft.displayName,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: 'e.g. DeepSeek'),
                  onChanged: (v) => _draft.displayName = v,
                ),
                const SizedBox(height: 10),
                _label(tr('set.baseUrl')),
                const SizedBox(height: 4),
                TextFormField(
                  initialValue: _draft.baseUrl,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: 'https://api.deepseek.com/v1'),
                  onChanged: (v) => _draft.baseUrl = v,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 10),
                _label(tr('set.model')),
                const SizedBox(height: 4),
                TextFormField(
                  initialValue: _draft.model,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: 'deepseek-chat'),
                  onChanged: (v) => _draft.model = v,
                  autocorrect: false,
                ),
                const SizedBox(height: 10),
                _label(tr('set.apiKey')),
                const SizedBox(height: 4),
                TextFormField(
                  initialValue: _draft.apiKey,
                  obscureText: !_revealKey,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    hintText: 'sk-...',
                    suffixIcon: IconButton(
                      icon: Icon(_revealKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                      onPressed: () => setState(() => _revealKey = !_revealKey),
                    ),
                  ),
                  onChanged: (v) => _draft.apiKey = v,
                  autocorrect: false,
                ),
                const SizedBox(height: 10),
                _label(tr('set.defaultMode')),
                const SizedBox(height: 4),
                DropdownButtonFormField<PolishMode>(
                  initialValue: _draft.defaultMode,
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  items: [
                    for (final m in PolishMode.values.where((m) => m != PolishMode.command))
                      DropdownMenuItem(value: m, child: Text(_modeLabelTr(m))),
                  ],
                  onChanged: (v) => setState(() => _draft.defaultMode = v ?? PolishMode.light),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: tr('set.testSection'),
            subtitle: tr('set.testSub'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _sampleCtrl,
                  decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true, labelText: tr('set.testSample')),
                  maxLines: 2,
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<PolishMode>(
                  initialValue: _testMode,
                  isExpanded: true,
                  decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true, labelText: tr('set.testMode')),
                  items: [
                    for (final m in PolishMode.values.where((m) => m != PolishMode.raw && m != PolishMode.command))
                      DropdownMenuItem(value: m, child: Text(_modeLabelTr(m))),
                  ],
                  onChanged: (v) => setState(() => _testMode = v ?? PolishMode.light),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  icon: _testing
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(_testing ? tr('set.testRunning') : tr('set.testRun')),
                  onPressed: (_testing || !_draft.isConfigured) ? null : _test,
                ),
                if (_testOut != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _testOk
                          ? cs.surfaceContainerHighest
                          : Color.alphaBlend(cs.errorContainer.withValues(alpha: 0.4), cs.surface),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _testOk ? cs.outlineVariant : cs.error.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      _testOut!,
                      style: TextStyle(
                        fontSize: 13,
                        color: _testOk ? cs.onSurface : cs.error,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _modeLabelTr(PolishMode m) {
  switch (m) {
    case PolishMode.raw:        return '${tr('polish.raw')} — ${tr('polish.rawDesc')}';
    case PolishMode.light:      return '${tr('polish.light')} — ${tr('polish.lightDesc')}';
    case PolishMode.structured: return '${tr('polish.structured')} — ${tr('polish.structuredDesc')}';
    case PolishMode.formal:     return '${tr('polish.formal')} — ${tr('polish.formalDesc')}';
    // IME-only voice-correction mode; filtered out of the dropdowns below.
    case PolishMode.command:    return tr('ime.correct');
  }
}

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(text, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500)),
    );

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const _Section({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(subtitle!, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5, height: 1.4)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

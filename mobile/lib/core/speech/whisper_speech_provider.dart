import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'speech_provider.dart';

/// Whisper-compatible batch ASR.
///
/// Records to a temp AAC/M4A file while the user holds the mic, then on stop()
/// POSTs the audio to `<baseUrl>/audio/transcriptions` and emits a single
/// SpeechEvent.finalResult. No partial results — that's the trade-off for
/// batch recognition. Works with OpenAI, Groq, local whisper.cpp servers,
/// any service exposing the same multipart form interface.
class WhisperSpeechProvider implements SpeechProvider {
  final String baseUrl;
  final String apiKey;
  final String model;
  final String language; // ISO 639-1; empty = auto-detect

  final AudioRecorder _recorder = AudioRecorder();
  StreamController<SpeechEvent>? _ctrl;
  String? _activePath;
  String? _lastError;
  bool _listening = false;

  WhisperSpeechProvider({
    required this.baseUrl,
    required this.apiKey,
    this.model = 'whisper-1',
    this.language = 'zh',
  });

  @override
  String? get lastError => _lastError;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize() async {
    if (apiKey.isEmpty || baseUrl.isEmpty) {
      _lastError = 'Whisper not configured (set base URL + API key in Settings)';
      return false;
    }
    // See VolcengineSpeechProvider.initialize: _recorder.hasPermission() returns
    // false in the IME (no Activity attached to the record plugin), so use
    // permission_handler, which checks the application context and works in both
    // the main app and the IME.
    if (!await Permission.microphone.isGranted) {
      _lastError = 'Microphone permission denied';
      return false;
    }
    _lastError = null;
    return true;
  }

  @override
  Stream<SpeechEvent> start({String locale = 'zh_CN'}) {
    _ctrl?.close();
    final ctrl = StreamController<SpeechEvent>.broadcast();
    _ctrl = ctrl;
    _listening = true;
    _record(ctrl);
    return ctrl.stream;
  }

  Future<void> _record(StreamController<SpeechEvent> ctrl) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/whisper_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _activePath = path;
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (e) {
      _listening = false;
      ctrl.add(SpeechEvent.error(e.toString()));
      ctrl.add(const SpeechEvent.done());
    }
  }

  @override
  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      _ctrl?.add(SpeechEvent.error('record stop: $e'));
      _ctrl?.add(const SpeechEvent.done());
      return;
    }
    final target = path ?? _activePath;
    if (target == null) {
      _ctrl?.add(SpeechEvent.error('no audio captured'));
      _ctrl?.add(const SpeechEvent.done());
      return;
    }
    try {
      final text = await _transcribe(File(target));
      _ctrl?.add(SpeechEvent.finalResult(text));
    } catch (e) {
      _ctrl?.add(SpeechEvent.error(e.toString()));
    } finally {
      _ctrl?.add(const SpeechEvent.done());
      try { await File(target).delete(); } catch (_) {}
    }
  }

  @override
  Future<void> cancel() async {
    _listening = false;
    try { await _recorder.cancel(); } catch (_) {}
    final p = _activePath;
    if (p != null) {
      try { await File(p).delete(); } catch (_) {}
    }
    await _ctrl?.close();
    _ctrl = null;
  }

  Future<String> _transcribe(File audio) async {
    final url = Uri.parse('${baseUrl.replaceAll(RegExp(r"/+$"), "")}/audio/transcriptions');
    final req = http.MultipartRequest('POST', url);
    req.headers['Authorization'] = 'Bearer $apiKey';
    req.fields['model'] = model;
    if (language.isNotEmpty) req.fields['language'] = language;
    req.fields['response_format'] = 'json';
    req.files.add(await http.MultipartFile.fromPath('file', audio.path));

    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 300) {
      throw 'HTTP ${resp.statusCode}: ${resp.body.trim()}';
    }
    final body = resp.body.trim();
    // Tolerate both `{"text":"..."}` and plain text replies.
    if (body.startsWith('{')) {
      final m = jsonDecode(body) as Map<String, dynamic>;
      final t = m['text'];
      if (t is String) return t.trim();
      return body;
    }
    return body;
  }
}

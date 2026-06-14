import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'speech_provider.dart';
import 'volcengine_protocol.dart';

/// Volcengine (火山引擎) streaming ASR via the v3 "bigmodel" WebSocket
/// endpoint. Sends a JSON config first, then PCM 16k/mono/16bit chunks at
/// ~100ms cadence; receives partial + final transcription frames.
///
/// Auth headers (set on the WebSocket upgrade request):
///   X-Api-App-Key       : the user's App ID
///   X-Api-Access-Key    : their access token
///   X-Api-Resource-Id   : "volc.bigasr.sauc.duration" (small model) /
///                         "volc.bigasr.sauc.bigmodel" (large model)
///   X-Api-Request-Id    : UUID per session
class VolcengineSpeechProvider implements SpeechProvider {
  final String appId;
  final String accessKey;
  final String resourceId; // "volc.bigasr.sauc.duration" by default
  final String endpoint;
  final List<String> hotwords; // injected into config so the model knows them
  final String language;

  final AudioRecorder _recorder = AudioRecorder();
  IOWebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  StreamSubscription<Uint8List>? _audioSub;
  StreamController<SpeechEvent>? _ctrl;
  int _sequence = 1;
  String _partialAccum = '';
  bool _listening = false;
  bool _finalEmitted = false;
  String? _lastError;

  VolcengineSpeechProvider({
    required this.appId,
    required this.accessKey,
    this.resourceId = 'volc.bigasr.sauc.duration',
    this.endpoint = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
    this.language = 'zh-CN',
    this.hotwords = const [],
  });

  @override
  String? get lastError => _lastError;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize() async {
    if (appId.isEmpty || accessKey.isEmpty) {
      _lastError = 'Volcengine app id / access key missing';
      return false;
    }
    // Check via permission_handler, NOT _recorder.hasPermission(): the `record`
    // plugin's PermissionManager returns false whenever no Activity is attached
    // (PermissionManager.kt: `if (activity == null) onResult(false)`), which is
    // ALWAYS the case in the IME engine — it's started from a Service and never
    // bound to an Activity. That false negative was the real cause of the IME
    // mic reporting "Microphone permission denied" even though RECORD_AUDIO is
    // granted. permission_handler queries the application context, so it reports
    // the true grant state in both the main app and the IME.
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
    _sequence = 1;
    _partialAccum = '';
    _finalEmitted = false;
    _listening = true;
    _startSession(ctrl);
    return ctrl.stream;
  }

  Future<void> _startSession(StreamController<SpeechEvent> ctrl) async {
    final reqId = const Uuid().v4();
    try {
      // The endpoint is user-editable in settings; trim accidental whitespace
      // and a trailing '#' (empty URI fragment), both of which Volcengine
      // rejects with HTTP 400 on the upgrade handshake.
      var ep = endpoint.trim();
      while (ep.endsWith('#') || ep.endsWith('/')) {
        ep = ep.substring(0, ep.length - 1);
      }
      debugPrint('[Volc] connect resource=$resourceId ep_raw=${endpoint.length}chars ep_clean=$ep');
      _channel = IOWebSocketChannel.connect(
        Uri.parse(ep),
        headers: {
          'X-Api-App-Key': appId,
          'X-Api-Access-Key': accessKey,
          'X-Api-Resource-Id': resourceId,
          'X-Api-Request-Id': reqId,
        },
        pingInterval: const Duration(seconds: 20),
      );

      _wsSub = _channel!.stream.listen(
        _onMessage,
        onError: (e) {
          _emitErrorAndStop(ctrl, 'ws error: $e');
        },
        onDone: () {
          if (!_finalEmitted) {
            ctrl.add(const SpeechEvent.done());
          }
        },
        cancelOnError: true,
      );

      // Send the FULL_CLIENT_REQUEST config first.
      final config = {
        'user': {'uid': 'voiceinput-mobile'},
        'audio': {
          'format': 'pcm',
          'codec': 'raw',
          'rate': 16000,
          'bits': 16,
          'channel': 1,
          'language': language,
        },
        'request': {
          'model_name': 'bigmodel',
          'enable_punc': true,
          'enable_itn': true,
          'show_utterances': false,
          if (hotwords.isNotEmpty) 'hotwords': hotwords,
        },
      };
      _channel!.sink.add(buildFullClientRequest(config, sequence: _sequence));
      _sequence++;

      // Start streaming PCM.
      final audioStream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      _audioSub = audioStream.listen(
        _onAudioChunk,
        onError: (e) => _emitErrorAndStop(ctrl, 'mic error: $e'),
      );
    } catch (e) {
      _emitErrorAndStop(ctrl, 'volcengine start: $e');
    }
  }

  void _onAudioChunk(Uint8List chunk) {
    final ch = _channel;
    if (ch == null || chunk.isEmpty) return;
    try {
      ch.sink.add(buildAudioRequest(chunk, _sequence));
      _sequence++;
    } catch (_) {/* socket gone; cleanup happens via onDone */}
  }

  void _onMessage(dynamic raw) {
    if (raw is! List<int>) return;
    final ctrl = _ctrl;
    if (ctrl == null) return;
    try {
      final frame = parseFrame(Uint8List.fromList(raw));
      if (frame.messageType == msgErrorMessage) {
        ctrl.add(SpeechEvent.error('volcengine_${frame.errorCode}'));
        return;
      }
      final text = frame.text;
      if (text == null) return;
      if (frame.isFinal) {
        _finalEmitted = true;
        ctrl.add(SpeechEvent.finalResult(text));
      } else {
        _partialAccum = text;
        ctrl.add(SpeechEvent.partial(text));
      }
    } catch (e) {
      ctrl.add(SpeechEvent.error('parse: $e'));
    }
  }

  void _emitErrorAndStop(StreamController<SpeechEvent> ctrl, String msg) {
    ctrl.add(SpeechEvent.error(msg));
    ctrl.add(const SpeechEvent.done());
    _listening = false;
    _shutdownSocket();
  }

  @override
  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    // Send the last audio frame with negative sequence to signal end-of-stream,
    // then close the socket. Fall-back: emit the last partial as final if the
    // server never confirms within a short window.
    try {
      _channel?.sink.add(buildAudioRequest(Uint8List(0), _sequence, isLast: true));
    } catch (_) {/* socket may already be gone */}
    await _recorder.stop();

    // Give the server up to 1.5 s to deliver the definite final result.
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!_finalEmitted && _partialAccum.isNotEmpty) {
        _ctrl?.add(SpeechEvent.finalResult(_partialAccum));
        _finalEmitted = true;
      }
      _ctrl?.add(const SpeechEvent.done());
      _shutdownSocket();
    });
  }

  @override
  Future<void> cancel() async {
    _listening = false;
    try { await _recorder.cancel(); } catch (_) {}
    _shutdownSocket();
    await _ctrl?.close();
    _ctrl = null;
  }

  void _shutdownSocket() {
    _wsSub?.cancel();
    _wsSub = null;
    _audioSub?.cancel();
    _audioSub = null;
    try {
      _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
  }
}

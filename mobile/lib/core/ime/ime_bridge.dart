import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart-side bridge to the native VoiceInputIme service.
///
/// Routes outgoing actions (commitText, commitKey, clearAll, switch IMEs)
/// down to the InputConnection on the Kotlin side, and surfaces lifecycle
/// events (onStartInput / onFinishInput) as a [Stream] so the IME UI can
/// react to focus changes in the host app.
class ImeBridge {
  static const _channel = MethodChannel('voiceinput/ime');

  ImeBridge() {
    debugPrint('[ImeBridge] ctor — registering channel handler on $_channel');
    _channel.setMethodCallHandler(_onCall);
  }

  final _eventsCtrl = StreamController<ImeEvent>.broadcast();
  Stream<ImeEvent> get events => _eventsCtrl.stream;

  Future<void> _onCall(MethodCall call) async {
    debugPrint('[ImeBridge] <- ${call.method} ${call.arguments}');
    switch (call.method) {
      case 'onStartInput':
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
        _eventsCtrl.add(ImeEvent.start(
          packageName: args['packageName'] as String?,
          fieldType: args['fieldType'] as String? ?? 'unknown',
          restarting: args['restarting'] == true,
        ));
        break;
      case 'onFinishInput':
        _eventsCtrl.add(const ImeEvent.finish());
        break;
    }
  }

  Future<void> commitText(String text) {
    debugPrint('[ImeBridge] -> commitText len=${text.length}');
    return _channel.invokeMethod('commitText', {'text': text});
  }

  Future<void> commitKey(String name) {
    debugPrint('[ImeBridge] -> commitKey $name');
    return _channel.invokeMethod('commitKey', {'name': name});
  }

  Future<void> clearAll() {
    debugPrint('[ImeBridge] -> clearAll');
    return _channel.invokeMethod('clearAll');
  }

  Future<bool> switchToPreviousIme() async {
    debugPrint('[ImeBridge] -> switchToPreviousIme');
    return (await _channel.invokeMethod<bool>('switchToPreviousIme')) ?? false;
  }

  Future<void> showImePicker() {
    debugPrint('[ImeBridge] -> showImePicker');
    return _channel.invokeMethod('showImePicker');
  }
}

class ImeEvent {
  final ImeEventKind kind;
  final String? packageName;
  final String fieldType;
  final bool restarting;
  const ImeEvent.start({
    required this.packageName,
    required this.fieldType,
    required this.restarting,
  }) : kind = ImeEventKind.start;
  const ImeEvent.finish()
      : kind = ImeEventKind.finish,
        packageName = null,
        fieldType = 'unknown',
        restarting = false;
}

enum ImeEventKind { start, finish }

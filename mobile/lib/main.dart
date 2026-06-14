import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/i18n/i18n.dart';
import 'features/ime/ime_keyboard_view.dart';
import 'features/voice_keyboard/voice_keyboard_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[main] entry');
  await I18n.instance.load();
  debugPrint('[main] i18n loaded, locale=${I18n.instance.locale.code}');
  runApp(const VoiceInputApp());
}

/// Dart entrypoint used by the native IME service. Must live in the same Dart
/// library as `main` — otherwise the AOT compiler tree-shakes it and the
/// FlutterEngine fails with "Could not resolve main entrypoint function".
@pragma('vm:entry-point')
void imeMain() {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[imeMain] entry');
  // Spin up the UI right away — blocking on I18n.load() before runApp leaves
  // the IME engine in a "view ready, no Dart frame" state on some platforms
  // (taps look ignored). Locale loads in the background and the
  // ListenableBuilder around MaterialApp re-renders when it lands.
  I18n.instance.load().then((_) {
    debugPrint('[imeMain] i18n loaded, locale=${I18n.instance.locale.code}');
  });
  runApp(const ImeApp());
  debugPrint('[imeMain] runApp returned');
}

/// PoC entrypoint (iOS keyboard-extension memory probe). Renders the smallest
/// possible always-animating Flutter UI so the embedding extension can measure
/// what a live FlutterEngine costs against the jetsam limit. Kept in this
/// library next to `main`/`imeMain` so the AOT compiler does not tree-shake the
/// @pragma-annotated entrypoint away.
@pragma('vm:entry-point')
void pocFlutterMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _PocApp());
}

class _PocApp extends StatelessWidget {
  const _PocApp();
  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFF101014),
          body: Center(child: _PocHeartbeat()),
        ),
      );
}

class _PocHeartbeat extends StatefulWidget {
  const _PocHeartbeat();
  @override
  State<_PocHeartbeat> createState() => _PocHeartbeatState();
}

class _PocHeartbeatState extends State<_PocHeartbeat> {
  int _ticks = 0;
  Timer? _t;
  @override
  void initState() {
    super.initState();
    // A steady repaint proves the isolate is alive and the raster pipeline is
    // resident — i.e. this is real engine memory, not a one-shot warm frame.
    _t = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _ticks++);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
        'Flutter alive in keyboard ext\ntick: $_ticks',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 18),
      );
}

class VoiceInputApp extends StatelessWidget {
  const VoiceInputApp({super.key});

  @override
  Widget build(BuildContext context) {
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1A1A1C),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1A1A1C),
      brightness: Brightness.dark,
    );
    return ListenableBuilder(
      listenable: I18n.instance,
      builder: (context, _) => MaterialApp(
        title: tr('app.title'),
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: lightScheme,
          scaffoldBackgroundColor: lightScheme.surface,
          appBarTheme: AppBarTheme(
              backgroundColor: lightScheme.surface, foregroundColor: lightScheme.onSurface),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: darkScheme,
          scaffoldBackgroundColor: darkScheme.surface,
          appBarTheme: AppBarTheme(
              backgroundColor: darkScheme.surface, foregroundColor: darkScheme.onSurface),
        ),
        home: const VoiceKeyboardPage(),
      ),
    );
  }
}

class ImeApp extends StatelessWidget {
  const ImeApp({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('[ImeApp] build');
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1A1A1C),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1A1A1C),
      brightness: Brightness.dark,
    );
    return ListenableBuilder(
      listenable: I18n.instance,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: lightScheme,
          scaffoldBackgroundColor: lightScheme.surface,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: darkScheme,
          scaffoldBackgroundColor: darkScheme.surface,
        ),
        // Standard bottom keyboard: the native IME service already sizes the
        // input view to a fixed height and docks it at the bottom, so here we
        // just fill that area with an opaque keyboard panel.
        home: const Scaffold(
          body: ImeKeyboardView(),
        ),
      ),
    );
  }
}

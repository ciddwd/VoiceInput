import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'polish.dart';
import 'prompts.dart';

/// OpenAI-compatible chat completions — handles real OpenAI plus DeepSeek,
/// Volcengine Ark, Doubao, Moonshot, Together AI, any vendor that mimics the
/// /v1/chat/completions endpoint.
class OpenAIPolishProvider implements PolishProvider {
  final String displayName;
  final String baseUrl;
  final String apiKey;
  final String model;
  final Map<PolishMode, String> promptOverrides;
  final http.Client _client;

  OpenAIPolishProvider({
    required this.displayName,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.promptOverrides = const {},
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  String get name => displayName.isEmpty ? 'OpenAI-compatible' : displayName;

  @override
  Future<PolishResult> polish(PolishRequest req) async {
    if (apiKey.isEmpty) throw const PolishException('API key not configured');
    if (baseUrl.isEmpty) throw const PolishException('Base URL not configured');
    if (model.isEmpty) throw const PolishException('Model not configured');

    final prompt = promptOverrides[req.mode] ?? defaultSystemPrompt(req.mode);
    if (prompt.isEmpty) {
      throw PolishException('No prompt available for mode ${req.mode}');
    }

    final url = Uri.parse('${baseUrl.replaceAll(RegExp(r"/+$"), "")}/chat/completions');
    final body = jsonEncode({
      'model': model,
      'temperature': 0.3,
      'max_tokens': 1024,
      'stream': false,
      'messages': [
        {'role': 'system', 'content': prompt},
        {'role': 'user', 'content': buildUserMessage(req)},
      ],
    });

    final resp = await _client.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: body,
    ).timeout(const Duration(seconds: 30));

    if (resp.statusCode >= 300) {
      throw PolishException('HTTP ${resp.statusCode}: ${utf8.decode(resp.bodyBytes).trim()}');
    }

    final parsed = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final err = parsed['error'];
    if (err is Map) {
      throw PolishException(err['message']?.toString() ?? 'unknown OpenAI error');
    }
    final choices = parsed['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw const PolishException('Empty response');
    }
    final content = ((choices.first as Map)['message'] as Map)['content']?.toString() ?? '';
    return PolishResult(
      text: content.trim(),
      model: parsed['model']?.toString() ?? model,
      provider: name,
    );
  }
}

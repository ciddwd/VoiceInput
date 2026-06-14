import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'polish.dart';
import 'prompts.dart';

class AnthropicPolishProvider implements PolishProvider {
  final String baseUrl;
  final String apiKey;
  final String model;
  final Map<PolishMode, String> promptOverrides;
  final http.Client _client;

  AnthropicPolishProvider({
    required this.apiKey,
    required this.model,
    this.baseUrl = 'https://api.anthropic.com',
    this.promptOverrides = const {},
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  String get name => 'Anthropic';

  @override
  Future<PolishResult> polish(PolishRequest req) async {
    if (apiKey.isEmpty) throw const PolishException('API key not configured');
    if (model.isEmpty) throw const PolishException('Model not configured');

    final prompt = promptOverrides[req.mode] ?? defaultSystemPrompt(req.mode);
    if (prompt.isEmpty) {
      throw PolishException('No prompt available for mode ${req.mode}');
    }

    final url = Uri.parse('${baseUrl.replaceAll(RegExp(r"/+$"), "")}/v1/messages');
    final body = jsonEncode({
      'model': model,
      'max_tokens': 1024,
      'system': prompt,
      'messages': [
        {'role': 'user', 'content': buildUserMessage(req)},
      ],
    });

    final resp = await _client.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: body,
    ).timeout(const Duration(seconds: 30));

    if (resp.statusCode >= 300) {
      throw PolishException('HTTP ${resp.statusCode}: ${utf8.decode(resp.bodyBytes).trim()}');
    }

    final parsed = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final err = parsed['error'];
    if (err is Map) {
      throw PolishException(err['message']?.toString() ?? 'unknown Anthropic error');
    }
    final content = parsed['content'] as List?;
    if (content == null) throw const PolishException('Empty response');
    final buf = StringBuffer();
    for (final c in content) {
      if (c is Map && c['type'] == 'text') buf.write(c['text']);
    }
    final text = buf.toString().trim();
    if (text.isEmpty) throw const PolishException('Empty text response');
    return PolishResult(
      text: text,
      model: parsed['model']?.toString() ?? model,
      provider: name,
    );
  }
}

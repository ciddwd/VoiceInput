import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Mirror of the desktop's snippets.Category. Field names match the wire
/// payload (camelCase) so JSON decoding is a straight read.
class SnippetCategory {
  final int id;
  final String name;
  final String prefix;
  final String suffix;
  final String defaultSendSuffix;
  final String matchAppRegex;
  final int sort;

  SnippetCategory({
    required this.id,
    required this.name,
    this.prefix = '',
    this.suffix = '',
    this.defaultSendSuffix = '',
    this.matchAppRegex = '',
    this.sort = 0,
  });

  factory SnippetCategory.fromJson(Map<String, dynamic> j) => SnippetCategory(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        prefix: j['prefix'] as String? ?? '',
        suffix: j['suffix'] as String? ?? '',
        defaultSendSuffix: j['defaultSendSuffix'] as String? ?? '',
        matchAppRegex: j['matchAppRegex'] as String? ?? '',
        sort: (j['sort'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'prefix': prefix, 'suffix': suffix,
        'defaultSendSuffix': defaultSendSuffix, 'matchAppRegex': matchAppRegex,
        'sort': sort,
      };
}

class SnippetItem {
  final int id;
  final int categoryId;
  final String label;
  final String content;
  final String hotkey;
  final int sort;

  SnippetItem({
    required this.id,
    required this.categoryId,
    required this.label,
    required this.content,
    this.hotkey = '',
    this.sort = 0,
  });

  factory SnippetItem.fromJson(Map<String, dynamic> j) => SnippetItem(
        id: (j['id'] as num).toInt(),
        categoryId: (j['categoryId'] as num).toInt(),
        label: j['label'] as String? ?? '',
        content: j['content'] as String? ?? '',
        hotkey: j['hotkey'] as String? ?? '',
        sort: (j['sort'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id, 'categoryId': categoryId, 'label': label,
        'content': content, 'hotkey': hotkey, 'sort': sort,
      };
}

class DictionaryEntry {
  final int id;
  final String term;
  final int sort;
  DictionaryEntry({required this.id, required this.term, this.sort = 0});

  factory DictionaryEntry.fromJson(Map<String, dynamic> j) => DictionaryEntry(
        id: (j['id'] as num?)?.toInt() ?? 0,
        term: j['term'] as String? ?? '',
        sort: (j['sort'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {'id': id, 'term': term, 'sort': sort};
}

class SnippetSnapshot {
  final List<SnippetCategory> categories;
  final List<SnippetItem> snippets;
  final List<DictionaryEntry> dictionary;
  final int revision;

  const SnippetSnapshot({
    this.categories = const [],
    this.snippets = const [],
    this.dictionary = const [],
    this.revision = 0,
  });

  factory SnippetSnapshot.fromJson(Map<String, dynamic> j) => SnippetSnapshot(
        categories: ((j['categories'] as List?) ?? [])
            .map((e) => SnippetCategory.fromJson(e as Map<String, dynamic>))
            .toList(),
        snippets: ((j['snippets'] as List?) ?? [])
            .map((e) => SnippetItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        dictionary: ((j['dictionary'] as List?) ?? [])
            .map((e) => DictionaryEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        revision: (j['revision'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'categories': categories.map((c) => c.toJson()).toList(),
        'snippets': snippets.map((s) => s.toJson()).toList(),
        'dictionary': dictionary.map((d) => d.toJson()).toList(),
        'revision': revision,
      };
}

/// Persists the latest snapshot received from the desktop so the IME / main
/// app shows chips immediately on cold start (before the WS is even up).
class SnippetStore {
  static const _kBlob = 'voiceinput.snippets.v1';

  final _ctrl = StreamController<SnippetSnapshot>.broadcast();
  SnippetSnapshot _current = const SnippetSnapshot();

  SnippetSnapshot get current => _current;
  Stream<SnippetSnapshot> get changes => _ctrl.stream;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kBlob);
    if (raw == null) return;
    try {
      _current = SnippetSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      _ctrl.add(_current);
    } catch (_) {/* stale; ignore */}
  }

  Future<void> apply(SnippetSnapshot snap) async {
    _current = snap;
    _ctrl.add(snap);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBlob, jsonEncode(snap.toJson()));
  }

  void dispose() => _ctrl.close();
}

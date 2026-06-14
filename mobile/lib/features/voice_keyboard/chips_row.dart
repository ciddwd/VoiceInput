import 'package:flutter/material.dart';

import '../../core/snippets/snippet_store.dart';

/// Horizontal chip strip shown above the buffer. Categories ride on the left
/// as compact pills, the right side shows the snippets in the active category.
/// Tapping a snippet chip yields its content via [onPick]; the host then
/// appends to its buffer.
class ChipsRow extends StatelessWidget {
  final SnippetSnapshot snapshot;
  final int? activeCategoryId;
  final ValueChanged<int> onSelectCategory;
  final ValueChanged<String> onPickSnippet;

  const ChipsRow({
    super.key,
    required this.snapshot,
    required this.activeCategoryId,
    required this.onSelectCategory,
    required this.onPickSnippet,
  });

  @override
  Widget build(BuildContext context) {
    if (snapshot.categories.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final items = snapshot.snippets
        .where((s) => s.categoryId == activeCategoryId)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              for (final c in snapshot.categories)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _Chip(
                    label: c.name,
                    selected: c.id == activeCategoryId,
                    onTap: () => onSelectCategory(c.id),
                  ),
                ),
            ],
          ),
        ),
        if (items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final s in items)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _Chip(
                        label: s.label,
                        selected: false,
                        onTap: () => onPickSnippet(s.content),
                        soft: true,
                      ),
                    ),
                ],
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Text(
              'No snippets here',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool soft;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.soft = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    final Color border;
    if (selected) {
      bg = cs.primary;
      fg = cs.onPrimary;
      border = cs.primary;
    } else if (soft) {
      bg = cs.surface;
      fg = cs.onSurface;
      border = cs.outlineVariant;
    } else {
      bg = cs.surfaceContainerHigh;
      fg = cs.onSurfaceVariant;
      border = cs.outlineVariant;
    }
    return Material(
      color: bg,
      shape: StadiumBorder(side: BorderSide(color: border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(label, style: TextStyle(color: fg, fontSize: 12)),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../src/model_catalog.dart';

/// Lets the user pick which languages the meeting is in. Returns the chosen
/// codes in display order (empty = detect any language), or null if
/// cancelled.
Future<List<String>?> showLanguageDialog(
  BuildContext context,
  List<String> selected,
) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => _LanguageDialog(initial: selected),
  );
}

String describeLanguages(List<String> codes) {
  if (codes.isEmpty) return 'Any language';
  return codes.map((c) => whisperLanguages[c] ?? c).join(' + ');
}

class _LanguageDialog extends StatefulWidget {
  const _LanguageDialog({required this.initial});

  final List<String> initial;

  @override
  State<_LanguageDialog> createState() => _LanguageDialogState();
}

class _LanguageDialogState extends State<_LanguageDialog> {
  late final Set<String> _selected = widget.initial.toSet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Languages spoken'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Pick every language people speak. Mixing languages in one '
              'sentence (e.g. Malay with English words) is fine.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final e in whisperLanguages.entries)
                  FilterChip(
                    label: Text(e.value),
                    selected: _selected.contains(e.key),
                    onSelected: (on) => setState(() {
                      on ? _selected.add(e.key) : _selected.remove(e.key);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _selected.isEmpty
                  ? 'Nothing selected: the language is detected '
                        'automatically. This is less reliable, e.g. Malay is '
                        'often mistaken for Indonesian.'
                  : _selected.length == 1
                  ? 'One language: fastest and most reliable.'
                  : 'Several languages: each sentence is checked and '
                        'transcribed in the right one. Can take a little '
                        'longer.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(_selected.clear),
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, [
            for (final code in whisperLanguages.keys)
              if (_selected.contains(code)) code,
          ]),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

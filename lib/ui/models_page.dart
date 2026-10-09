import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/model_catalog.dart';
import '../src/model_downloads.dart';

class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key, required this.downloads});

  final ModelDownloads downloads;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Speech models')),
      body: ListenableBuilder(
        listenable: downloads,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                'Download a model once (needs internet). After that, '
                'transcription runs completely offline on this device.',
              ),
            ),
            for (final model in modelCatalog)
              _ModelTile(model: model, downloads: downloads),
            const SizedBox(height: 16),
            _ManualInstallNote(dir: downloads.manager.modelsDir),
          ],
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.model, required this.downloads});

  final ModelInfo model;
  final ModelDownloads downloads;

  @override
  Widget build(BuildContext context) {
    final installed = downloads.manager.isInstalled(model);
    final busy = downloads.isBusy(model);
    final progress = downloads.progress[model.id];
    final error = downloads.errors[model.id];
    final theme = Theme.of(context);

    Widget trailing;
    if (busy) {
      trailing = const SizedBox.shrink();
    } else if (installed) {
      trailing = IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('Delete ${model.title}?'),
              content: const Text('You can download it again later.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (ok == true) await downloads.delete(model);
        },
      );
    } else {
      trailing = FilledButton.tonalIcon(
        icon: const Icon(Icons.download),
        label: Text('${model.downloadMb} MB'),
        onPressed: () => downloads.download(model),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(switch (model.kind) {
                  EngineKind.streaming => Icons.bolt,
                  EngineKind.whisper => Icons.translate,
                  EngineKind.parakeet => Icons.record_voice_over,
                }, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(model.title, style: theme.textTheme.titleMedium),
                ),
                if (installed && !busy)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Chip(
                      label: const Text('Installed'),
                      avatar: const Icon(Icons.check, size: 18),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                trailing,
              ],
            ),
            if (model.badge != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  model.badge!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(model.description, style: theme.textTheme.bodyMedium),
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 4),
              Text(
                progress == null
                    ? 'Unpacking… (large models can take a few minutes)'
                    : 'Downloading… ${(progress * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ManualInstallNote extends StatelessWidget {
  const _ManualInstallNote({required this.dir});

  final String dir;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'No internet on this device?',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Download the model .tar.bz2 on another computer from the '
              'sherpa-onnx "asr-models" release, unpack it, and copy the '
              'folder (and silero_vad.onnx for Whisper and Parakeet) into:',
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    dir,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy path',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => Clipboard.setData(ClipboardData(text: dir)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

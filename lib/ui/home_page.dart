import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/audio_capture.dart';
import '../src/engine.dart';
import '../src/model_catalog.dart';
import '../src/model_downloads.dart';
import '../src/model_manager.dart';
import '../src/settings.dart';
import '../src/transcript.dart';
import 'models_page.dart';

enum _State { idle, starting, running, stopping }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ModelDownloads? _downloads;
  Settings? _settings;
  Set<AudioSourceKind> _sources = {};

  AudioSourceKind _source = AudioSourceKind.system;
  String? _modelId;
  String _language = '';

  _State _state = _State.idle;
  final _capture = AudioCapture();
  TranscriberSession? _session;
  StreamSubscription<TranscriptUpdate>? _updates;
  TranscriptFile? _file;
  int? _sampleRate;
  final _early = <Float32List>[];

  final _lines = <TranscriptLine>[];
  String _partial = '';
  final _level = ValueNotifier<double>(0);
  final _elapsed = ValueNotifier<Duration>(Duration.zero);
  Timer? _clock;
  DateTime? _startedAt;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final manager = await ModelManager.create();
    final settings = await Settings.load();
    final sources = await AudioCapture.supportedSources();
    final downloads = ModelDownloads(manager)..addListener(_onModelsChanged);
    if (!mounted) return;
    setState(() {
      _downloads = downloads;
      _settings = settings;
      _sources = sources;
      _source = AudioSourceKind.values.firstWhere(
        (s) => s.name == settings.getString('source'),
        orElse: () => sources.contains(AudioSourceKind.system)
            ? AudioSourceKind.system
            : AudioSourceKind.mic,
      );
      if (!sources.contains(_source) && sources.isNotEmpty) {
        _source = sources.first;
      }
      _modelId = settings.getString('model');
      _language = settings.getString('language') ?? '';
      _ensureModelSelected();
    });
  }

  void _onModelsChanged() => setState(_ensureModelSelected);

  List<ModelInfo> get _installed {
    final d = _downloads;
    if (d == null) return const [];
    return modelCatalog.where(d.manager.isInstalled).toList();
  }

  void _ensureModelSelected() {
    final installed = _installed;
    if (installed.any((m) => m.id == _modelId)) return;
    _modelId = installed.isEmpty ? null : installed.first.id;
  }

  @override
  void dispose() {
    _capture.stop();
    _session?.stop();
    _clock?.cancel();
    _downloads?.removeListener(_onModelsChanged);
    _scroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- actions

  Future<void> _start() async {
    final model = modelById(_modelId);
    final config = model == null
        ? null
        : _downloads!.manager.engineConfig(model, language: _language);
    if (config == null) {
      _toast('Download a speech model first');
      return;
    }
    setState(() {
      _state = _State.starting;
      _partial = '';
    });

    try {
      final session = await TranscriberSession.start(config);
      _session = session;
      _updates = session.updates.listen(
        _onUpdate,
        onError: (Object e) => _toast('$e'),
      );
      _file = await TranscriptFile.create(DateTime.now());
      _sampleRate = null;
      _early.clear();
      final rate = await _capture.start(
        _source,
        onData: _onAudio,
        onError: (message) {
          _toast(message);
          _stop();
        },
        onDone: () {
          if (_state == _State.running) _stop();
        },
      );
      _sampleRate = rate;
      for (final chunk in _early) {
        session.addAudio(chunk, rate);
      }
      _early.clear();
    } catch (e) {
      await _teardown();
      if (mounted) setState(() => _state = _State.idle);
      _toast(e is AudioCaptureException ? e.message : '$e');
      return;
    }

    _startedAt = DateTime.now();
    _elapsed.value = Duration.zero;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsed.value = DateTime.now().difference(_startedAt!);
    });
    if (mounted) setState(() => _state = _State.running);
  }

  Future<void> _stop() async {
    if (_state != _State.running) return;
    setState(() => _state = _State.stopping);
    await _teardown();
    if (mounted) {
      setState(() {
        _state = _State.idle;
        _partial = '';
      });
    }
  }

  Future<void> _teardown() async {
    _clock?.cancel();
    _clock = null;
    _level.value = 0;
    await _capture.stop();
    final session = _session;
    _session = null;
    if (session != null) {
      await session.stop(); // Delivers the last sentence.
    }
    await _updates?.cancel();
    _updates = null;
  }

  void _onAudio(Float32List samples) {
    final rate = _sampleRate;
    if (rate == null) {
      _early.add(samples);
    } else {
      _session?.addAudio(samples, rate);
    }
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    final rms = samples.isEmpty ? 0.0 : math.sqrt(sum / samples.length);
    // Map roughly -60..0 dBFS to 0..1.
    final db = 20 * math.log(rms + 1e-9) / math.ln10;
    final level = ((db + 60) / 60).clamp(0.0, 1.0);
    _level.value = math.max(level, _level.value * 0.8);
  }

  void _onUpdate(TranscriptUpdate update) {
    if (!mounted) return;
    final atBottom =
        !_scroll.hasClients ||
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
    setState(() {
      if (update.isFinal) {
        final line = TranscriptLine(DateTime.now(), update.text);
        _lines.add(line);
        _partial = '';
        _file?.append(line);
      } else {
        _partial = update.text;
      }
    });
    if (atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: transcriptToText(_lines)));
    _toast('Transcript copied');
  }

  Future<void> _showSaved() async {
    final dir = await transcriptsDirectory();
    if (!mounted) return;
    final current = _file?.file.path;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Saved transcripts'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Every session is saved automatically as a .txt file in:',
            ),
            const SizedBox(height: 8),
            SelectableText(dir.path),
            if (current != null) ...[
              const SizedBox(height: 12),
              const Text('Latest file:'),
              SelectableText(current.split(Platform.pathSeparator).last),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: dir.path)),
            child: const Text('Copy folder path'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _clear() => setState(() {
    _lines.clear();
    _partial = '';
  });

  Future<void> _openModels() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelsPage(downloads: _downloads!),
      ),
    );
    setState(_ensureModelSelected);
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final ready = _downloads != null;
    final busy = _state != _State.idle;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transcribe'),
        actions: [
          IconButton(
            tooltip: 'Copy transcript',
            icon: const Icon(Icons.copy_all),
            onPressed: _lines.isEmpty ? null : _copyAll,
          ),
          IconButton(
            tooltip: 'Saved transcripts',
            icon: const Icon(Icons.folder_open),
            onPressed: _showSaved,
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _lines.isEmpty || busy ? null : _clear,
          ),
          IconButton(
            tooltip: 'Speech models',
            icon: const Icon(Icons.download_for_offline_outlined),
            onPressed: ready && !busy ? _openModels : null,
          ),
        ],
      ),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildControls(context),
                const Divider(height: 1),
                Expanded(child: _buildTranscript(context)),
                _buildStatusBar(context),
              ],
            ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final busy = _state != _State.idle;
    final installed = _installed;
    final model = modelById(_modelId);

    if (installed.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: ListTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: const Text('Download a speech model to get started'),
            subtitle: const Text(
              'One-time download. Everything after that works offline.',
            ),
            trailing: FilledButton(
              onPressed: _openModels,
              child: const Text('Models'),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<AudioSourceKind>(
            segments: [
              ButtonSegment(
                value: AudioSourceKind.system,
                icon: const Icon(Icons.speaker),
                label: Text(Platform.isAndroid ? 'Other apps' : 'System audio'),
                enabled: _sources.contains(AudioSourceKind.system),
              ),
              const ButtonSegment(
                value: AudioSourceKind.mic,
                icon: Icon(Icons.mic),
                label: Text('Microphone'),
              ),
            ],
            selected: {_source},
            onSelectionChanged: busy
                ? null
                : (s) {
                    setState(() => _source = s.first);
                    _settings?.setString('source', s.first.name);
                  },
          ),
          DropdownMenu<String>(
            key: ValueKey('model-${installed.length}'),
            enabled: !busy,
            label: const Text('Model'),
            initialSelection: _modelId,
            width: 280,
            dropdownMenuEntries: [
              for (final m in installed)
                DropdownMenuEntry(value: m.id, label: m.title),
            ],
            onSelected: (id) {
              setState(() => _modelId = id);
              _settings?.setString('model', id);
            },
          ),
          if (model?.kind == EngineKind.whisper)
            DropdownMenu<String>(
              enabled: !busy,
              label: const Text('Language'),
              initialSelection: _language,
              width: 200,
              dropdownMenuEntries: [
                for (final e in whisperLanguages.entries)
                  DropdownMenuEntry(value: e.key, label: e.value),
              ],
              onSelected: (code) {
                setState(() => _language = code ?? '');
                _settings?.setString('language', code ?? '');
              },
            ),
        ],
      ),
    );
  }

  Widget _buildTranscript(BuildContext context) {
    final theme = Theme.of(context);
    if (_lines.isEmpty && _partial.isEmpty) {
      return _EmptyHint(running: _state == _State.running, source: _source);
    }
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _lines.length + (_partial.isEmpty ? 0 : 1),
        itemBuilder: (context, i) {
          final isPartial = i == _lines.length;
          final time = isPartial ? DateTime.now() : _lines[i].time;
          final text = isPartial ? _partial : _lines[i].text;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  child: Text(
                    formatClock(time),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    text,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: isPartial ? theme.colorScheme.outline : null,
                      fontStyle: isPartial ? FontStyle.italic : null,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatusBar(BuildContext context) {
    final theme = Theme.of(context);
    final canStart = _installed.isNotEmpty;
    final (label, icon, action) = switch (_state) {
      _State.idle => ('Start', Icons.play_arrow, canStart ? _start : null),
      _State.starting => ('Starting…', Icons.hourglass_top, null),
      _State.running => ('Stop', Icons.stop, _stop),
      _State.stopping => ('Finishing…', Icons.hourglass_bottom, null),
    };

    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: _state == _State.running
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ValueListenableBuilder(
                            valueListenable: _elapsed,
                            builder: (_, d, _) => Text(
                              'Listening · ${_formatDuration(d)}',
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ValueListenableBuilder(
                            valueListenable: _level,
                            builder: (_, v, _) => ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: v,
                                minHeight: 6,
                              ),
                            ),
                          ),
                        ],
                      )
                    : Text(
                        _state == _State.idle
                            ? '${_lines.length} lines · works offline'
                            : _state == _State.starting
                            ? 'Loading model…'
                            : 'Transcribing the last words…',
                        style: theme.textTheme.labelLarge,
                      ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: action,
                icon: Icon(icon),
                label: Text(label),
                style: _state == _State.running
                    ? FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.running, required this.source});

  final bool running;
  final AudioSourceKind source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String title;
    final String body;
    if (running) {
      title = 'Listening…';
      body = source == AudioSourceKind.system
          ? 'Play your meeting or video. Text appears here as people speak.'
          : 'Speak, or hold the device near the speaker.';
    } else if (Platform.isAndroid) {
      title = 'Transcribe meetings and videos offline';
      body =
          '"Other apps" captures sound from YouTube, browsers and most '
          'video apps (Android 10+).\n\n'
          'Android does not let any app record call audio from Google Meet, '
          'Zoom, WhatsApp etc. For calls, choose "Microphone" and put the '
          'call on speaker.';
    } else {
      title = 'Transcribe meetings and videos offline';
      body =
          '"System audio" captures everything playing through your '
          'speakers or headphones: Google Meet, Zoom, Teams, YouTube…\n\n'
          'It does not include your own voice. Choose "Microphone" to '
          'transcribe yourself.';
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            children: [
              Icon(
                running ? Icons.hearing : Icons.subtitles_outlined,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                body,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

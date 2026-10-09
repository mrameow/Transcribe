import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'model_catalog.dart';
import 'resampler.dart';

const engineSampleRate = 16000;

/// Everything needed to build an engine. Sent to the background isolate.
class EngineConfig {
  const EngineConfig({
    required this.kind,
    required this.files,
    this.vadModel,
    this.language = '',
    this.sentenceCase = false,
    this.numThreads = 2,
  });

  final EngineKind kind;
  final ModelFiles files;
  final String? vadModel;
  final String language;
  final bool sentenceCase;
  final int numThreads;
}

/// A piece of recognised text. Partial text may still change; final text is
/// a finished sentence/utterance.
class TranscriptUpdate {
  const TranscriptUpdate(this.text, {required this.isFinal});

  final String text;
  final bool isFinal;

  @override
  String toString() => '${isFinal ? 'final' : 'partial'}: $text';
}

abstract class TranscriptionEngine {
  factory TranscriptionEngine(EngineConfig config) => switch (config.kind) {
    EngineKind.streaming => StreamingEngine(config),
    EngineKind.whisper => WhisperEngine(config),
  };

  /// Feeds 16 kHz mono samples in the range [-1, 1].
  List<TranscriptUpdate> accept(Float32List samples);

  /// Processes any buffered audio and returns the remaining text.
  List<TranscriptUpdate> finish();

  void free();
}

/// Streaming zipformer transducer with endpoint detection.
class StreamingEngine implements TranscriptionEngine {
  StreamingEngine(this.config) {
    final f = config.files;
    _recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: f.encoder,
            decoder: f.decoder,
            joiner: f.joiner!,
          ),
          tokens: f.tokens,
          numThreads: config.numThreads,
          debug: false,
        ),
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 0.8,
        rule3MinUtteranceLength: 20,
      ),
    );
    _stream = _recognizer.createStream();
  }

  final EngineConfig config;
  late final sherpa.OnlineRecognizer _recognizer;
  late sherpa.OnlineStream _stream;
  String _lastPartial = '';

  @override
  List<TranscriptUpdate> accept(Float32List samples) {
    _stream.acceptWaveform(samples: samples, sampleRate: engineSampleRate);
    return _drain(endpointOnly: false);
  }

  List<TranscriptUpdate> _drain({required bool endpointOnly}) {
    while (_recognizer.isReady(_stream)) {
      _recognizer.decode(_stream);
    }
    final text = _format(_recognizer.getResult(_stream).text);
    if (endpointOnly || _recognizer.isEndpoint(_stream)) {
      _recognizer.reset(_stream);
      _lastPartial = '';
      return text.isEmpty ? const [] : [TranscriptUpdate(text, isFinal: true)];
    }
    if (text != _lastPartial) {
      _lastPartial = text;
      return [TranscriptUpdate(text, isFinal: false)];
    }
    return const [];
  }

  String _format(String raw) {
    final text = raw.trim();
    if (!config.sentenceCase || text.isEmpty) return text;
    final lower = text.toLowerCase().replaceAllMapped(
      RegExp(r"\bi\b(?='|\s|$)"),
      (_) => 'I',
    );
    return lower[0].toUpperCase() + lower.substring(1);
  }

  @override
  List<TranscriptUpdate> finish() {
    // Trailing silence lets the model flush its last words.
    _stream.acceptWaveform(
      samples: Float32List(engineSampleRate ~/ 2),
      sampleRate: engineSampleRate,
    );
    _stream.inputFinished();
    final out = _drain(endpointOnly: true);
    _stream.free();
    _stream = _recognizer.createStream();
    return out;
  }

  @override
  void free() {
    _stream.free();
    _recognizer.free();
  }
}

/// Whisper run on speech segments cut by the Silero voice activity detector.
class WhisperEngine implements TranscriptionEngine {
  WhisperEngine(this.config) {
    final f = config.files;
    _recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: f.encoder,
            decoder: f.decoder,
            language: config.language,
            task: 'transcribe',
          ),
          tokens: f.tokens,
          numThreads: config.numThreads,
          debug: false,
          modelType: 'whisper',
        ),
      ),
    );
    _vadConfig = sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: config.vadModel!,
        threshold: 0.5,
        minSilenceDuration: 0.6,
        minSpeechDuration: 0.25,
        maxSpeechDuration: 20,
      ),
      sampleRate: engineSampleRate,
      numThreads: 1,
      debug: false,
    );
    _vad = sherpa.VoiceActivityDetector(
      config: _vadConfig,
      bufferSizeInSeconds: 60,
    );
  }

  final EngineConfig config;
  late final sherpa.OfflineRecognizer _recognizer;
  late final sherpa.VadModelConfig _vadConfig;
  late final sherpa.VoiceActivityDetector _vad;

  final _pending = <double>[];
  bool _speaking = false;

  int get _window => _vadConfig.sileroVad.windowSize;

  @override
  List<TranscriptUpdate> accept(Float32List samples) {
    _pending.addAll(samples);
    final out = <TranscriptUpdate>[];
    var offset = 0;
    while (_pending.length - offset >= _window) {
      _vad.acceptWaveform(
        Float32List.fromList(_pending.sublist(offset, offset + _window)),
      );
      offset += _window;
      out.addAll(_decodeSegments());
    }
    _pending.removeRange(0, offset);

    final speaking = _vad.isDetected();
    if (speaking != _speaking) {
      _speaking = speaking;
      if (speaking) out.add(const TranscriptUpdate('…', isFinal: false));
    }
    return out;
  }

  List<TranscriptUpdate> _decodeSegments() {
    final out = <TranscriptUpdate>[];
    while (!_vad.isEmpty()) {
      final segment = _vad.front();
      _vad.pop();
      final text = transcribe(segment.samples);
      if (text.isNotEmpty) out.add(TranscriptUpdate(text, isFinal: true));
    }
    return out;
  }

  /// Transcribes one chunk of 16 kHz audio.
  String transcribe(Float32List samples) {
    final stream = _recognizer.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: engineSampleRate);
    _recognizer.decode(stream);
    final text = _recognizer.getResult(stream).text.trim();
    stream.free();
    return _isNoise(text) ? '' : text;
  }

  /// Whisper writes things like "[Music]" or "(upbeat music)" for non-speech.
  static bool _isNoise(String text) =>
      text.isEmpty ||
      RegExp(r'^[\[\(\*♪].*[\]\)\*♪]$').hasMatch(text) ||
      !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text);

  @override
  List<TranscriptUpdate> finish() {
    if (_pending.isNotEmpty) {
      _vad.acceptWaveform(Float32List.fromList(_pending));
      _pending.clear();
    }
    _vad.flush();
    final out = _decodeSegments();
    _vad.reset();
    _speaking = false;
    return out;
  }

  @override
  void free() {
    _vad.free();
    _recognizer.free();
  }
}

/// Runs a [TranscriptionEngine] on a background isolate so recognition never
/// blocks the UI.
class TranscriberSession {
  TranscriberSession._(this._isolate, this._commands, this.updates, this._done);

  final Isolate _isolate;
  final SendPort _commands;
  final Completer<void> _done;

  /// Recognised text, in order.
  final Stream<TranscriptUpdate> updates;

  static Future<TranscriberSession> start(EngineConfig config) async {
    final fromIsolate = ReceivePort();
    final isolate = await Isolate.spawn(
      _isolateMain,
      _StartMessage(fromIsolate.sendPort, config),
      debugName: 'transcriber',
      errorsAreFatal: true,
    );
    final ready = Completer<SendPort>();
    final updates = StreamController<TranscriptUpdate>();
    final done = Completer<void>();
    fromIsolate.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is TranscriptUpdate) {
        updates.add(message);
      } else if (message is _Failure) {
        final error = StateError(message.message);
        if (!ready.isCompleted) {
          ready.completeError(error);
        } else {
          updates.addError(error);
        }
      } else if (message == _doneMsg) {
        fromIsolate.close();
        updates.close();
        if (!done.isCompleted) done.complete();
      }
    });
    try {
      final commands = await ready.future;
      return TranscriberSession._(isolate, commands, updates.stream, done);
    } catch (_) {
      fromIsolate.close();
      isolate.kill();
      rethrow;
    }
  }

  /// Adds captured audio at any sample rate; it is resampled to 16 kHz in the
  /// background isolate.
  void addAudio(Float32List samples, int sampleRate) {
    _commands.send(
      _AudioMessage(TransferableTypedData.fromList([samples]), sampleRate),
    );
  }

  /// Transcribes any remaining audio, then shuts the isolate down.
  Future<void> stop() async {
    _commands.send(_finishCmd);
    await _done.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _isolate.kill();
      },
    );
  }
}

const _finishCmd = 'finish';
const _doneMsg = 'done';

class _StartMessage {
  const _StartMessage(this.replyTo, this.config);
  final SendPort replyTo;
  final EngineConfig config;
}

class _AudioMessage {
  const _AudioMessage(this.samples, this.sampleRate);
  final TransferableTypedData samples;
  final int sampleRate;
}

class _Failure {
  const _Failure(this.message);
  final String message;
}

void _isolateMain(_StartMessage start) {
  final out = start.replyTo;
  final TranscriptionEngine engine;
  try {
    sherpa.initBindings();
    engine = TranscriptionEngine(start.config);
  } catch (e) {
    out.send(_Failure('Could not load the speech model: $e'));
    out.send(_doneMsg);
    return;
  }

  Resampler? resampler;
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((message) {
    try {
      if (message is _AudioMessage) {
        var samples = message.samples.materialize().asFloat32List();
        if (message.sampleRate != engineSampleRate) {
          if (resampler?.inputRate != message.sampleRate) {
            resampler = Resampler(message.sampleRate, engineSampleRate);
          }
          samples = resampler!.process(samples);
        }
        engine.accept(samples).forEach(out.send);
      } else if (message == _finishCmd) {
        engine.finish().forEach(out.send);
        engine.free();
        inbox.close();
        out.send(_doneMsg);
      }
    } catch (e) {
      out.send(_Failure('Transcription error: $e'));
    }
  });
}

/// Resolves the absolute paths of a model's files inside [dir].
ModelFiles? resolveModelFiles(String dir, EngineKind kind) {
  final names = <String>[];
  try {
    for (final e in Directory(dir).listSync(recursive: true)) {
      if (e is File) names.add(e.path);
    }
  } on FileSystemException {
    return null;
  }
  names.sort();
  return pickModelFiles(names, kind);
}

String vadPathIn(String modelsDir) => p.join(modelsDir, vadFileName);

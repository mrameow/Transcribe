// End-to-end recognition test with real models. Downloads are large, so this
// only runs when TRANSCRIBE_TEST_ARCHIVES points at a folder containing
// sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2,
// sherpa-onnx-whisper-tiny.tar.bz2, silero_vad.onnx and a 16 kHz test wav.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:transcribe/src/engine.dart';
import 'package:transcribe/src/model_catalog.dart';
import 'package:transcribe/src/model_manager.dart';

void main() {
  final archives = Platform.environment['TRANSCRIBE_TEST_ARCHIVES'];
  final skip = archives == null ? 'set TRANSCRIBE_TEST_ARCHIVES' : null;
  late Directory tmp;

  setUpAll(() {
    if (archives == null) return;
    tmp = Directory.systemTemp.createTempSync('transcribe_test');
    sherpa.initBindings();
  });

  tearDownAll(() {
    if (archives != null) tmp.deleteSync(recursive: true);
  });

  Future<List<TranscriptUpdate>> run(
    ModelInfo model, {
    List<String> languages = const ['en'],
    List<String> wavs = const ['test.wav'],
  }) async {
    final dir = p.join(tmp.path, model.id);
    final copy = File(p.join(archives!, '${model.id}.tar.bz2'))
        .copySync(p.join(tmp.path, 'copy.tar.bz2'));
    await unpackModelArchive(copy.path, dir, model.kind);
    final files = resolveModelFiles(dir, model.kind)!;
    final session = await TranscriberSession.start(
      EngineConfig(
        kind: model.kind,
        files: files,
        vadModel: p.join(archives, vadFileName),
        languages: languages,
        sentenceCase: model.sentenceCase,
      ),
    );
    final updates = <TranscriptUpdate>[];
    final sub = session.updates.listen(updates.add);
    // Feed in 100 ms chunks like the live capture does, with silence after
    // each clip.
    const audioRate = 16000;
    final samples = Float32List.fromList([
      for (final wav in wavs) ...[
        ...sherpa.readWave(p.join(archives, wav)).samples,
        ...Float32List(audioRate * 3 ~/ 2),
      ],
    ]);
    final chunk = audioRate ~/ 10;
    for (var i = 0; i < samples.length; i += chunk) {
      session.addAudio(
        Float32List.sublistView(
          samples,
          i,
          i + chunk > samples.length ? samples.length : i + chunk,
        ),
        audioRate,
      );
    }
    await session.stop();
    await sub.cancel();
    return updates;
  }

  String finals(List<TranscriptUpdate> u) =>
      u.where((x) => x.isFinal).map((x) => x.text).join(' ').toLowerCase();

  test(
    'streaming model transcribes speech',
    () async {
      final updates = await run(
        modelById('sherpa-onnx-streaming-zipformer-en-20M-2023-02-17')!,
      );
      expect(updates.any((u) => !u.isFinal), isTrue);
      expect(finals(updates), contains('yellow lamps'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'whisper model transcribes speech',
    () async {
      final updates = await run(modelById('sherpa-onnx-whisper-tiny')!);
      expect(finals(updates), contains('yellow lamps'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  bool has(String id) =>
      archives != null && File(p.join(archives, '$id.tar.bz2')).existsSync();

  test(
    'parakeet transcribes English with punctuation',
    () async {
      const id = 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8';
      final updates = await run(modelById(id)!);
      expect(
        updates.where((u) => u.isFinal).map((u) => u.text).join(' '),
        contains('After early nightfall'),
      );
    },
    skip: has('sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8')
        ? null
        : 'needs the Parakeet archive',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // ms.wav / en.wav: short Malay and English sentences (16 kHz), e.g.
  // "Selamat pagi semua..." and "Good morning everyone...".
  test(
    'whisper picks between Malay and English per sentence',
    () async {
      final updates = await run(
        modelById('sherpa-onnx-whisper-turbo')!,
        languages: ['en', 'ms'],
        wavs: ['ms.wav', 'en.wav'],
      );
      final text = finals(updates);
      expect(text, contains('selamat pagi semua'));
      expect(text, contains('good morning everyone'));
    },
    skip:
        has('sherpa-onnx-whisper-turbo') &&
            File(p.join(archives ?? '', 'ms.wav')).existsSync()
        ? null
        : 'needs Whisper Turbo and ms.wav/en.wav',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

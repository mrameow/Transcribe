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
  late Float32List audio;
  late int audioRate;

  setUpAll(() {
    if (archives == null) return;
    tmp = Directory.systemTemp.createTempSync('transcribe_test');
    sherpa.initBindings();
    final wave = sherpa.readWave(p.join(archives, 'test.wav'));
    audio = wave.samples;
    audioRate = wave.sampleRate;
  });

  tearDownAll(() {
    if (archives != null) tmp.deleteSync(recursive: true);
  });

  Future<List<TranscriptUpdate>> run(ModelInfo model) async {
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
        language: 'en',
        sentenceCase: model.sentenceCase,
      ),
    );
    final updates = <TranscriptUpdate>[];
    final sub = session.updates.listen(updates.add);
    // Feed in 100 ms chunks like the live capture does, followed by silence.
    final samples = Float32List.fromList([...audio, ...Float32List(audioRate)]);
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
      final updates = await run(modelCatalog[0]);
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
}

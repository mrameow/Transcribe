import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe/src/model_catalog.dart';
import 'package:transcribe/src/resampler.dart';

void main() {
  test('picks int8 streaming files and ignores test audio', () {
    const dir = 'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17';
    final files = pickModelFiles([
      '$dir/tokens.txt',
      '$dir/encoder-epoch-99-avg-1.int8.onnx',
      '$dir/decoder-epoch-99-avg-1.int8.onnx',
      '$dir/test_wavs/0.wav',
      '$dir/decoder-epoch-99-avg-1.onnx',
      '$dir/encoder-epoch-99-avg-1.onnx',
      '$dir/joiner-epoch-99-avg-1.int8.onnx',
      '$dir/joiner-epoch-99-avg-1.onnx',
    ], EngineKind.streaming)!;
    expect(files.encoder, '$dir/encoder-epoch-99-avg-1.int8.onnx');
    expect(files.decoder, '$dir/decoder-epoch-99-avg-1.int8.onnx');
    expect(files.joiner, '$dir/joiner-epoch-99-avg-1.int8.onnx');
    expect(files.tokens, '$dir/tokens.txt');
  });

  test('picks whisper files, falls back to fp32', () {
    final files = pickModelFiles([
      'w/tiny-encoder.onnx',
      'w/tiny-decoder.int8.onnx',
      'w/tiny-tokens.txt',
    ], EngineKind.whisper)!;
    expect(files.encoder, 'w/tiny-encoder.onnx');
    expect(files.decoder, 'w/tiny-decoder.int8.onnx');
    expect(files.joiner, isNull);
  });

  test('reports missing files', () {
    expect(
      pickModelFiles(['a/tokens.txt', 'a/encoder.onnx'], EngineKind.whisper),
      isNull,
    );
    expect(
      pickModelFiles([
        'a/tokens.txt',
        'a/encoder.onnx',
        'a/decoder.onnx',
      ], EngineKind.streaming),
      isNull,
    );
  });

  test('resampler keeps duration and frequency across blocks', () {
    const inRate = 48000;
    final r = Resampler(inRate, 16000);
    final out = <double>[];
    var t = 0;
    for (var block = 0; block < 100; block++) {
      final size = 480 + block % 7; // uneven block sizes
      final x = Float32List(size);
      for (var i = 0; i < size; i++, t++) {
        x[i] = math.sin(2 * math.pi * 440 * t / inRate);
      }
      out.addAll(r.process(x));
    }
    expect(out.length, closeTo(t / 3, 2));
    // Count zero crossings: 440 Hz => ~880 per second.
    var crossings = 0;
    for (var i = 1; i < out.length; i++) {
      if ((out[i - 1] < 0) != (out[i] < 0)) crossings++;
    }
    final seconds = out.length / 16000;
    expect(crossings / seconds, closeTo(880, 15));
  });
}

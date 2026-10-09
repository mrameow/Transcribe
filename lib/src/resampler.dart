import 'dart:math' as math;
import 'dart:typed_data';

/// Streaming sample-rate converter (linear interpolation with a light
/// low-pass filter when downsampling). Good enough for speech recognition,
/// which only needs the 0–8 kHz band.
class Resampler {
  Resampler(this.inputRate, this.outputRate)
    : _step = inputRate / outputRate,
      _alpha = inputRate > outputRate
          ? 1 - math.exp(-2 * math.pi * (0.45 * outputRate) / inputRate)
          : 1.0;

  final int inputRate;
  final int outputRate;
  final double _step;
  final double _alpha;

  /// Position of the next output sample, relative to the start of the next
  /// input block. -1 refers to the last sample of the previous block.
  double _pos = 0;
  double _prev = 0;
  double _lp = 0;

  Float32List process(Float32List input) {
    if (inputRate == outputRate || input.isEmpty) return input;

    final x = input;
    if (_alpha < 1) {
      final filtered = Float32List(input.length);
      var y = _lp;
      for (var i = 0; i < input.length; i++) {
        y += _alpha * (input[i] - y);
        filtered[i] = y;
      }
      _lp = y;
      return _interpolate(filtered);
    }
    return _interpolate(x);
  }

  Float32List _interpolate(Float32List x) {
    final n = x.length;
    final out = Float32List(((n - _pos) / _step).ceil() + 1);
    var count = 0;
    while (_pos <= n - 1) {
      final i = _pos.floor();
      final frac = _pos - i;
      final a = i < 0 ? _prev : x[i];
      final b = x[i + 1 < n ? i + 1 : n - 1];
      out[count++] = a + (b - a) * frac;
      _pos += _step;
    }
    _pos -= n;
    _prev = x[n - 1];
    return Float32List.sublistView(out, 0, count);
  }
}

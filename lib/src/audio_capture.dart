import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

enum AudioSourceKind {
  /// Audio other apps are playing (meetings, videos). Windows: WASAPI
  /// loopback of the default output. Android 10+: AudioPlaybackCapture.
  system,

  /// The microphone.
  mic,

  /// Windows: system audio and microphone mixed, so both sides of a meeting
  /// (the other people and you) are transcribed.
  both,
}

/// Talks to the native audio capture code in `android/` and `windows/runner/`.
class AudioCapture {
  static const _control = MethodChannel('transcribe/control');
  static const _audio = EventChannel('transcribe/audio');

  StreamSubscription<dynamic>? _subscription;

  /// Which sources this device supports.
  static Future<Set<AudioSourceKind>> supportedSources() async {
    try {
      final caps = await _control.invokeMapMethod<String, bool>('capabilities');
      return {
        if (caps?['system'] ?? false) AudioSourceKind.system,
        if (caps?['mic'] ?? false) AudioSourceKind.mic,
        if (caps?['both'] ?? false) AudioSourceKind.both,
      };
    } on MissingPluginException {
      return {};
    }
  }

  /// Starts capturing and returns the sample rate of the delivered audio.
  Future<int> start(
    AudioSourceKind source, {
    required void Function(Float32List samples) onData,
    required void Function(String message) onError,
    required void Function() onDone,
  }) async {
    await stop();
    _subscription = _audio.receiveBroadcastStream().listen(
      (event) {
        if (event is Float32List) onData(event);
      },
      onError: (Object e) =>
          onError(e is PlatformException ? (e.message ?? e.code) : '$e'),
      onDone: onDone,
    );
    try {
      final rate = await _control.invokeMethod<int>('start', {
        'source': source.name,
      });
      return rate ?? 16000;
    } on PlatformException catch (e) {
      await _cancel();
      throw AudioCaptureException(e.message ?? e.code);
    } on MissingPluginException {
      await _cancel();
      throw const AudioCaptureException(
        'Audio capture is only available on Android and Windows',
      );
    }
  }

  /// Android: whether the "Transcribe call helper" accessibility service is
  /// on. It is needed to hear the microphone while a call app (Google Meet,
  /// Zoom...) is active, and it shows the floating captions.
  static Future<bool> callHelperEnabled() async {
    if (!Platform.isAndroid) return false;
    return await _control.invokeMethod<bool>('callHelperEnabled') ?? false;
  }

  static Future<void> openCallHelperSettings() =>
      _control.invokeMethod<void>('openCallHelperSettings');

  static Future<void> openAppSettings() =>
      _control.invokeMethod<void>('openAppSettings');

  /// Text for the floating caption box (Android call helper).
  static Future<void> showCaptions(String text) async {
    if (!Platform.isAndroid) return;
    try {
      await _control.invokeMethod<void>('captions', {'text': text});
    } on MissingPluginException {
      // Not available.
    }
  }

  Future<void> stop() async {
    if (_subscription == null) return;
    try {
      await _control.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Nothing to stop.
    }
    await _cancel();
  }

  Future<void> _cancel() async {
    final s = _subscription;
    _subscription = null;
    await s?.cancel();
  }
}

class AudioCaptureException implements Exception {
  const AudioCaptureException(this.message);
  final String message;

  @override
  String toString() => message;
}

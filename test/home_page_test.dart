import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:transcribe/main.dart';
import 'package:transcribe/src/model_catalog.dart';
import 'package:transcribe/src/model_manager.dart';

class _FakePaths extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePaths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => p.join(root, 'support');

  @override
  Future<String?> getApplicationDocumentsPath() async => p.join(root, 'docs');

  @override
  Future<String?> getExternalStoragePath() async => p.join(root, 'ext');
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('transcribe_ui');
    PathProviderPlatform.instance = _FakePaths(root.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('transcribe/control'), (
          call,
        ) async {
          if (call.method == 'capabilities') {
            return {'system': true, 'mic': true, 'both': true};
          }
          return null;
        });
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const TranscribeApp());
      // Let the async init (file system, channels) finish.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
  }

  testWidgets('asks for a model when none is installed', (tester) async {
    await pumpApp(tester);
    expect(find.text('Download a speech model to get started'), findsOneWidget);

    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();
    expect(find.text('Speech models'), findsOneWidget);
    expect(find.text('Whisper Turbo · Multilingual'), findsOneWidget);
    expect(find.text('Best for Malay + English'), findsOneWidget);
  });

  testWidgets('shows controls when a model is installed', (tester) async {
    final dir = Directory(
      p.join(root.path, 'support', 'models', 'sherpa-onnx-whisper-tiny'),
    )..createSync(recursive: true);
    for (final f in [
      'tiny-encoder.int8.onnx',
      'tiny-decoder.int8.onnx',
      'tiny-tokens.txt',
    ]) {
      File(p.join(dir.path, f)).writeAsBytesSync(Uint8List(1));
    }
    File(p.join(root.path, 'support', 'models', 'silero_vad.onnx'))
        .writeAsBytesSync(Uint8List(1));

    await pumpApp(tester);
    expect(find.text('System audio'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('System + mic'), findsOneWidget);
    expect(find.text('English + Malay'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
  });

  // Full pipeline: fake audio events -> background engine -> transcript UI.
  // Needs real models, see engine_test.dart.
  final archives = Platform.environment['TRANSCRIBE_TEST_ARCHIVES'];
  testWidgets('transcribes captured audio end to end', (tester) async {
    const id = 'sherpa-onnx-whisper-tiny';
    final models = p.join(root.path, 'support', 'models');
    Directory(models).createSync(recursive: true);
    late Float32List audio;
    await tester.runAsync(() async {
      final copy = File(p.join(archives!, '$id.tar.bz2'))
          .copySync(p.join(models, 'a.tar.bz2'));
      await unpackModelArchive(
        copy.path,
        p.join(models, id),
        EngineKind.whisper,
      );
      File(p.join(archives, 'silero_vad.onnx'))
          .copySync(p.join(models, 'silero_vad.onnx'));
      sherpa.initBindings();
      audio = sherpa.readWave(p.join(archives, 'test.wav')).samples;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('transcribe/audio'),
          MockStreamHandler.inline(
            onListen: (args, sink) {
              // Deliver 100 ms chunks, then 1.5 s of silence.
              final all = Float32List.fromList([
                ...audio,
                ...Float32List(24000),
              ]);
              for (var i = 0; i < all.length; i += 1600) {
                sink.success(
                  Float32List.sublistView(
                    all,
                    i,
                    i + 1600 > all.length ? all.length : i + 1600,
                  ),
                );
              }
            },
          ),
        );

    await pumpApp(tester);
    await tester.tap(find.text('Start'));
    await tester.runAsync(() async {
      for (var i = 0; i < 300 && find.text('Stop').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
      // Wait for the sentence to be recognised.
      for (
        var i = 0;
        i < 600 && find.textContaining('yellow lamps').evaluate().isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(find.textContaining('yellow lamps'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && find.text('Start').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(find.text('Start'), findsOneWidget);
    final saved = Directory(p.join(root.path, 'docs', 'Transcribe'))
        .listSync()
        .whereType<File>()
        .single
        .readAsStringSync();
    expect(saved, contains('yellow lamps'));
  }, skip: archives == null);
}

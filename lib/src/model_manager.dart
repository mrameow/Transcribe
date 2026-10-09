import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'engine.dart';
import 'model_catalog.dart';

/// Downloads, unpacks and locates speech models on the device.
///
/// Models live in `<app support dir>/models/<model id>/`. You can also copy an
/// unpacked sherpa-onnx model folder there by hand to install it without
/// using the in-app downloader.
class ModelManager {
  ModelManager(this.modelsDir);

  final String modelsDir;

  static Future<ModelManager> create() async {
    final support = await getApplicationSupportDirectory();
    final dir = p.join(support.path, 'models');
    await Directory(dir).create(recursive: true);
    return ModelManager(dir);
  }

  String dirFor(ModelInfo model) => p.join(modelsDir, model.id);

  String get vadPath => vadPathIn(modelsDir);

  bool isInstalled(ModelInfo model) =>
      resolveModelFiles(dirFor(model), model.kind) != null &&
      (!model.needsVad || File(vadPath).existsSync());

  EngineConfig? engineConfig(
    ModelInfo model, {
    List<String> languages = const [],
  }) {
    final files = resolveModelFiles(dirFor(model), model.kind);
    if (files == null) return null;
    return EngineConfig(
      kind: model.kind,
      files: files,
      vadModel: model.needsVad ? vadPath : null,
      languages: model.multilingual ? languages : const [],
      sentenceCase: model.sentenceCase,
      numThreads: (Platform.numberOfProcessors - 1).clamp(2, 6),
    );
  }

  Future<void> delete(ModelInfo model) async {
    final dir = Directory(dirFor(model));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Downloads and installs [model]. [onProgress] receives a value between 0
  /// and 1 while downloading, and null while unpacking.
  Future<void> install(
    ModelInfo model, {
    required void Function(double? progress) onProgress,
  }) async {
    final client = http.Client();
    try {
      if (model.needsVad && !File(vadPath).existsSync()) {
        await _download(client, vadUrl, vadPath, (_) {});
      }
      final archive = p.join(modelsDir, '${model.id}.tar.bz2.part');
      await _download(client, model.url, archive, onProgress);
      onProgress(null);
      final target = dirFor(model);
      await Isolate.run(() => unpackModelArchive(archive, target, model.kind));
    } finally {
      client.close();
    }
  }

  Future<void> _download(
    http.Client client,
    String url,
    String dest,
    void Function(double) onProgress,
  ) async {
    final response = await client.send(http.Request('GET', Uri.parse(url)));
    if (response.statusCode != 200) {
      throw HttpException(
        'Download failed (HTTP ${response.statusCode})',
        uri: Uri.parse(url),
      );
    }
    final total = response.contentLength ?? 0;
    final tmp = File('$dest.download');
    final sink = tmp.openWrite();
    var received = 0;
    var lastReport = DateTime.now();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (total > 0 && now.difference(lastReport).inMilliseconds > 100) {
          lastReport = now;
          onProgress(received / total);
        }
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
    if (total > 0 && received != total) {
      await tmp.delete();
      throw const HttpException('Download was interrupted');
    }
    await tmp.rename(dest);
  }
}

/// Unpacks only the files the engine needs (skipping test audio and the
/// larger non-quantised duplicates) from a .tar.bz2 archive into [target].
Future<void> unpackModelArchive(
  String archivePath,
  String target,
  EngineKind kind,
) async {
  final tarPath = '$archivePath.tar';
  try {
    final input = InputFileStream(archivePath);
    final output = OutputFileStream(tarPath);
    BZip2Decoder().decodeStream(input, output);
    await input.close();
    await output.close();

    final tarInput = InputFileStream(tarPath);
    final archive = TarDecoder().decodeStream(tarInput);
    final files = archive.files.where((f) => f.isFile).toList();
    final picked = pickModelFiles(files.map((f) => f.name), kind);
    if (picked == null) {
      throw const FormatException(
        'The archive does not contain a usable model',
      );
    }
    final wanted = {
      picked.encoder,
      picked.decoder,
      picked.tokens,
      if (picked.joiner != null) picked.joiner!,
    };

    final staging = Directory('$target.unpacking');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    for (final file in files) {
      if (!wanted.contains(file.name)) continue;
      final out = OutputFileStream(p.join(staging.path, p.basename(file.name)));
      file.writeContent(out);
      await out.close();
    }
    await tarInput.close();
    await archive.clear();

    final dest = Directory(target);
    if (await dest.exists()) await dest.delete(recursive: true);
    await staging.rename(target);
  } finally {
    for (final path in [archivePath, tarPath]) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
  }
}

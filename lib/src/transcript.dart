import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class TranscriptLine {
  TranscriptLine(this.time, this.text);
  final DateTime time;
  final String text;
}

String formatClock(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String _two(int n) => n.toString().padLeft(2, '0');

String transcriptToText(List<TranscriptLine> lines) =>
    lines.map((l) => '[${formatClock(l.time)}] ${l.text}').join('\n');

/// The folder transcripts go to when the user has not picked one.
Future<Directory> defaultTranscriptsDirectory() async {
  if (Platform.isAndroid) {
    // The shared Documents folder is easy to find in the Files app. Android
    // 11+ lets apps create files there without any permission.
    final shared = Directory('/storage/emulated/0/Documents/Transcribe');
    if (await isWritableDirectory(shared.path)) return shared;
    final base =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'Transcripts'));
    await dir.create(recursive: true);
    return dir;
  }
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(base.path, 'Transcribe'));
  await dir.create(recursive: true);
  return dir;
}

/// Where transcripts are saved: [customPath] if it can be written to,
/// otherwise the default folder.
Future<Directory> transcriptsDirectory(String? customPath) async {
  if (customPath != null &&
      customPath.isNotEmpty &&
      await isWritableDirectory(customPath)) {
    return Directory(customPath);
  }
  return defaultTranscriptsDirectory();
}

/// Creates [path] if needed and checks that a file can be written in it.
Future<bool> isWritableDirectory(String path) async {
  try {
    final dir = Directory(path);
    await dir.create(recursive: true);
    final probe = File(p.join(path, '.transcribe-write-test'));
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// Appends each finished line to a text file so nothing is lost if the app
/// is closed.
class TranscriptFile {
  TranscriptFile._(this.file);
  final File file;

  static Future<TranscriptFile> create(Directory dir, DateTime start) async {
    final name =
        'transcript-${start.year}-${_two(start.month)}-${_two(start.day)}'
        '_${_two(start.hour)}-${_two(start.minute)}-${_two(start.second)}.txt';
    return TranscriptFile._(File(p.join(dir.path, name)));
  }

  Future<void> append(TranscriptLine line) => file.writeAsString(
    '[${formatClock(line.time)}] ${line.text}\n',
    mode: FileMode.append,
    flush: true,
  );
}

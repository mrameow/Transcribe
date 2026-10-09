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

/// Where transcripts are saved automatically.
Future<Directory> transcriptsDirectory() async {
  Directory base;
  if (Platform.isAndroid) {
    base =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
  } else {
    base = await getApplicationDocumentsDirectory();
  }
  final dir = Directory(
    p.join(base.path, Platform.isAndroid ? 'Transcripts' : 'Transcribe'),
  );
  await dir.create(recursive: true);
  return dir;
}

/// Appends each finished line to a text file so nothing is lost if the app
/// is closed.
class TranscriptFile {
  TranscriptFile._(this.file);
  final File file;

  static Future<TranscriptFile> create(DateTime start) async {
    final dir = await transcriptsDirectory();
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

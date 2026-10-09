import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Small JSON-backed settings store.
class Settings {
  Settings._(this._file, this._values);

  final File _file;
  final Map<String, dynamic> _values;

  static Future<Settings> load() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'settings.json'));
    var values = <String, dynamic>{};
    try {
      if (await file.exists()) {
        values = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {
      // Corrupt settings: start fresh.
    }
    return Settings._(file, values);
  }

  String? getString(String key) => _values[key] as String?;

  Future<void> setString(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(_values));
  }
}

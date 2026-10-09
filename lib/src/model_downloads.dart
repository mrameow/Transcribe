import 'package:flutter/foundation.dart';

import 'model_catalog.dart';
import 'model_manager.dart';

/// Tracks model downloads so they keep going while the user moves between
/// screens.
class ModelDownloads extends ChangeNotifier {
  ModelDownloads(this.manager);

  final ModelManager manager;

  /// Model id -> progress (0..1), or null while unpacking.
  final Map<String, double?> progress = {};
  final Map<String, String> errors = {};

  bool isBusy(ModelInfo m) => progress.containsKey(m.id);

  Future<void> download(ModelInfo model) async {
    if (isBusy(model)) return;
    errors.remove(model.id);
    progress[model.id] = 0;
    notifyListeners();
    try {
      await manager.install(
        model,
        onProgress: (value) {
          progress[model.id] = value;
          notifyListeners();
        },
      );
    } catch (e) {
      errors[model.id] = 'Download failed: $e';
    } finally {
      progress.remove(model.id);
      notifyListeners();
    }
  }

  Future<void> delete(ModelInfo model) async {
    await manager.delete(model);
    notifyListeners();
  }
}

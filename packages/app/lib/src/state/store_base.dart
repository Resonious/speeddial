import 'package:flutter/foundation.dart';

/// ChangeNotifier that silently drops notifications after disposal.
///
/// Stores in this graph perform unawaited async work (startup refreshes,
/// demo turns) that can complete after the owning AppData is disposed —
/// without this guard, a late notifyListeners throws in debug builds.
abstract class StoreBase extends ChangeNotifier {
  bool _disposed = false;

  /// True after [dispose].
  bool get isDisposed => _disposed;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

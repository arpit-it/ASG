import 'package:flutter/foundation.dart';

abstract class BaseController extends ChangeNotifier {
  bool _disposed = false;
  bool get isDisposed => _disposed;
  void update() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

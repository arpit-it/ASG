// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

class FolderPicker {
  bool get supported => !kIsWeb && defaultTargetPlatform != TargetPlatform.iOS;
  Future<String?> pick() => getDirectoryPath();
}

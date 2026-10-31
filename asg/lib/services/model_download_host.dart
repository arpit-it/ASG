// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/model_download.dart';
import '../models/runtime_setup.dart';

/// Optional transfer controls; existing runtime adapters remain compatible.
abstract interface class ModelDownloadHost {
  ModelDownloadProgress get downloadProgress;
  Stream<ModelDownloadProgress> get downloadEvents;
  Future<String> resumeDownload(RuntimeSetup setup);
  Future<void> pauseDownload();
  Future<void> stopDownload();
}

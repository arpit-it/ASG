// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/runtime_setup.dart';
import '../models/runtime_capabilities.dart';

abstract interface class RuntimeHost {
  bool get supported;
  bool get ownsProcess;
  bool get loading;
  bool get working;
  Stream<String> get events;
  Future<String?> chooseDirectory();
  Future<String?> choosePython();
  Future<List<ModelCandidate>> scan(String path);
  Future<void> prepare(String python);
  Future<RuntimeCapabilities> discover(String python);
  Future<String> download(RuntimeSetup setup);
  Future<void> start(RuntimeSetup setup, String modelId);
  Future<void> stop();
}

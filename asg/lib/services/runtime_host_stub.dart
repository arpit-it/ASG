// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/runtime_setup.dart';
import 'runtime_host.dart';

RuntimeHost createRuntimeHost() => _host;
final _host = UnsupportedRuntimeHost();

class UnsupportedRuntimeHost implements RuntimeHost {
  @override
  bool get supported => false;
  @override
  bool get ownsProcess => false;
  @override
  bool get loading => false;
  @override
  bool get working => false;
  @override
  Stream<String> get events => const Stream.empty();
  Never _unsupported() => throw UnsupportedError(
    'Managed local inference setup requires the macOS app. Connect to an existing runtime on this platform.',
  );
  @override
  Future<String?> chooseDirectory() async => _unsupported();
  @override
  Future<String?> choosePython() async => _unsupported();
  @override
  Future<List<ModelCandidate>> scan(String path) async => _unsupported();
  @override
  Future<void> prepare(String python) async => _unsupported();
  @override
  Future<String> download(RuntimeSetup setup) async => _unsupported();
  @override
  Future<void> start(RuntimeSetup setup, String modelId) async =>
      _unsupported();
  @override
  Future<void> stop() async => _unsupported();
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'imported_dart_diagnostics_host.dart';
import 'imported_dart_diagnostics_host_stub.dart'
    if (dart.library.io) 'imported_dart_diagnostics_host_native.dart'
    as platform;

ImportedDartDiagnosticsHost createImportedDartDiagnosticsHost() =>
    platform.createImportedDartDiagnosticsHost();

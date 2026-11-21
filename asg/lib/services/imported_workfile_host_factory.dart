// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'imported_workfile_host.dart';
import 'imported_workfile_host_stub.dart'
    if (dart.library.io) 'imported_workfile_host_native.dart'
    as platform;

ImportedWorkfileHost createImportedWorkfileHost() =>
    platform.createImportedWorkfileHost();

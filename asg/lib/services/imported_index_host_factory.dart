// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'imported_index_host.dart';
import 'imported_index_host_stub.dart'
    if (dart.library.io) 'imported_index_host_native.dart'
    as platform;

ImportedIndexHost createImportedIndexHost() =>
    platform.createImportedIndexHost();

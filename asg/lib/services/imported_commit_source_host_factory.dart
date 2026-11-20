// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'imported_commit_source_host.dart';
import 'imported_commit_source_host_stub.dart'
    if (dart.library.io) 'imported_commit_source_host_native.dart'
    as platform;

ImportedCommitSourceHost createImportedCommitSourceHost() =>
    platform.createImportedCommitSourceHost();

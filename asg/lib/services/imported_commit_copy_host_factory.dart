// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'imported_commit_copy_host.dart';
import 'imported_commit_copy_host_stub.dart'
    if (dart.library.io) 'imported_commit_copy_host_native.dart'
    as platform;

ImportedCommitCopyHost createImportedCommitCopyHost() =>
    platform.createImportedCommitCopyHost();

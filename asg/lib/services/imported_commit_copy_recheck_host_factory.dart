// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'imported_commit_copy_recheck_host.dart';
import 'imported_commit_copy_recheck_host_stub.dart'
    if (dart.library.io) 'imported_commit_copy_recheck_host_native.dart'
    as platform;

ImportedCommitCopyRecheckHost createImportedCommitCopyRecheckHost() =>
    platform.createImportedCommitCopyRecheckHost();

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'imported_commit_edit_comparison_host.dart';
import 'imported_commit_edit_comparison_host_stub.dart'
    if (dart.library.io) 'imported_commit_edit_comparison_host_native.dart'
    as platform;

ImportedCommitEditComparisonHost createImportedCommitEditComparisonHost() =>
    platform.createImportedCommitEditComparisonHost();

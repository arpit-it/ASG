// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'git_metadata_host.dart';
import 'git_metadata_host_stub.dart'
    if (dart.library.io) 'git_metadata_host_native.dart'
    as platform;

GitMetadataHost createGitMetadataHost() => platform.createGitMetadataHost();

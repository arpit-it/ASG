// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'project_metadata_host.dart';
import 'project_metadata_host_stub.dart'
    if (dart.library.io) 'project_metadata_host_native.dart'
    as platform;

ProjectMetadataHost createProjectMetadataHost() =>
    platform.createProjectMetadataHost();

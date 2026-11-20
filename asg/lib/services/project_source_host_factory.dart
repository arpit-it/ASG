// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'project_source_host.dart';
import 'project_source_host_stub.dart'
    if (dart.library.io) 'project_source_host_native.dart'
    as platform;

ProjectSourceHost createProjectSourceHost() =>
    platform.createProjectSourceHost();

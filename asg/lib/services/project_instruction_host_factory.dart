// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'project_instruction_host.dart';
import 'project_instruction_host_stub.dart'
    if (dart.library.io) 'project_instruction_host_native.dart'
    as platform;

ProjectInstructionHost createProjectInstructionHost() =>
    platform.createProjectInstructionHost();

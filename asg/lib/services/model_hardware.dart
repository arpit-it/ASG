// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/model_catalog.dart';
import 'model_hardware_stub.dart'
    if (dart.library.io) 'model_hardware_native.dart'
    as platform;

Future<ModelHardware> probeModelHardware() => platform.probeModelHardware();

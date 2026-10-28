// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/model_catalog.dart';

Future<ModelHardware> probeModelHardware() async => const ModelHardware(
  appleSilicon: false,
  detail: 'Browser clients cannot inspect Mac hardware. Use the macOS app for managed model setup.',
);

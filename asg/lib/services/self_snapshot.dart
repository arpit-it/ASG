// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

export 'self_snapshot_stub.dart'
    if (dart.library.io) 'self_snapshot_native.dart';

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

export 'database_factory_native.dart'
    if (dart.library.js_interop) 'database_factory_web.dart';

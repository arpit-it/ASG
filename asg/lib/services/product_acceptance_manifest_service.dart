// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/services.dart';

import '../models/product_acceptance_manifest.dart';

class ProductAcceptanceManifestService {
  Future<ProductAcceptanceManifest> load() async =>
      ProductAcceptanceManifest.parse(
        await rootBundle.loadString(
          'docs/development/product_acceptance_manifest.json',
        ),
      );
}

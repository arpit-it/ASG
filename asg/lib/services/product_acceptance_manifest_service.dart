// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/services.dart';

import '../models/product_acceptance_manifest.dart';

class ProductAcceptanceManifestService {
  ProductAcceptanceManifestService({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  Future<ProductAcceptanceManifest> load() async =>
      ProductAcceptanceManifest.parse(
        await _bundle.loadString(
          'docs/development/product_acceptance_manifest.json',
          // The controller owns the loaded manifest. A cached failed string
          // future would prevent its explicit retry from reading the asset.
          cache: false,
        ),
      );
}

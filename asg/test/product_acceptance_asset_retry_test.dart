// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/product_acceptance_controller.dart';
import 'package:asg/services/product_acceptance_manifest_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class RecoveringBundle extends CachingAssetBundle {
  bool available = false;
  int reads = 0;

  @override
  Future<ByteData> load(String key) async {
    reads++;
    if (!available) throw StateError('asset unavailable');
    return ByteData.sublistView(
      Uint8List.fromList(
        utf8.encode(
          File('docs/development/product_acceptance_manifest.json')
              .readAsStringSync(),
        ),
      ),
    );
  }
}

void main() {
  test(
    'retry recovers a failed caching bundle without losing inspected report',
    () async {
      final bundle = RecoveringBundle();
      final service = ProductAcceptanceManifestService(bundle: bundle);
      final controller = ProductAcceptanceController(
        manifestLoader: service.load,
      );
      addTearDown(controller.dispose);
      controller.inspect(
        File('test/fixtures/product_acceptance_report.json').readAsStringSync(),
      );
      final report = controller.report;
      await controller.loadManifest();
      expect(controller.manifestError, isNotNull);
      expect(controller.comparison, isNull);
      expect(bundle.reads, 1);

      bundle.available = true;
      await controller.loadManifest();
      expect(bundle.reads, 2);
      expect(controller.manifestError, isNull);
      expect(controller.report, same(report));
      expect(controller.comparison!.manifestMatches, isFalse);
      expect(controller.comparison!.absentChecks.length, 9);
    },
  );
}

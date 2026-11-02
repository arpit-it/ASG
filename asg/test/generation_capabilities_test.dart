// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:asg/models/generation_capabilities.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/generation_host_stub.dart';
import 'package:asg/views/generation_capability_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native report follows actual host without toolchain or model probes',
    () async {
      final host = NativeGenerationHost(
        loadAsset: (_) async => throw StateError('No asset read permitted'),
      );
      expect(host.capabilities.implemented, Platform.isMacOS);
      expect(
        host.capabilities.operations.every(
          (entry) => entry.implemented == host.supported,
        ),
        isTrue,
      );
      expect(
        () => host.capabilities.operations.clear(),
        throwsUnsupportedError,
      );
      await host.dispose();
    },
  );
  test(
    'unsupported and unknown reports never inherit execution support',
    () async {
      final host = UnsupportedGenerationHost();
      expect(host.capabilities.implemented, isFalse);
      expect(
        const GenerationCapabilities.unknown().operations.every(
          (entry) => !entry.implemented,
        ),
        isTrue,
      );
      await host.dispose();
    },
  );
  for (final report in [
    const GenerationCapabilities.macOS(),
    const GenerationCapabilities.unavailable('Windows'),
  ]) {
    testWidgets('narrow enlarged report: ${report.host}', (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: GenerationCapabilityPanel(report: report),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Generation host capabilities'));
      await tester.pumpAndSettle();
      expect(find.text(GenerationCapabilities.limits), findsOneWidget);
      final cleanup = find.textContaining('Process cleanup:');
      await tester.ensureVisible(cleanup);
      await tester.pumpAndSettle();
      expect(cleanup, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

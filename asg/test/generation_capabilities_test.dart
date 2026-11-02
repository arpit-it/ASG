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
      expect(host.capabilities.starterCreation, Platform.isMacOS);
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
      expect(host.capabilities.starterCreation, isFalse);
      expect(
        const GenerationCapabilities.unknown().operations.every(
          (entry) => !entry.implemented,
        ),
        isTrue,
      );
      await host.dispose();
    },
  );
  test('starter reporting cannot inherit candidate confinement', () {
    const report = GenerationCapabilities(
      host: 'Starter-only reporting fixture',
      starterCreation: true,
      starterVerification: true,
      webPreview: true,
      processCleanup: true,
    );
    expect(report.candidateConfinement, isFalse);
    expect(
      report.operations
          .singleWhere(
            (entry) =>
                entry.operation == GenerationOperation.candidateConfinement,
          )
          .implemented,
      isFalse,
    );
    expect(report.implementsOperation(GenerationOperation.webPreview), isTrue);
    expect(() => report.operations.clear(), throwsUnsupportedError);
  });
  test('each operation reports only its explicit implementation', () {
    for (final enabled in GenerationOperation.values) {
      final report = GenerationCapabilities(
        host: 'Independent operation fixture',
        starterCreation: enabled == GenerationOperation.starterCreation,
        starterVerification: enabled == GenerationOperation.starterVerification,
        candidateConfinement:
            enabled == GenerationOperation.candidateConfinement,
        webPreview: enabled == GenerationOperation.webPreview,
        processCleanup: enabled == GenerationOperation.processCleanup,
      );
      expect(
        report.operations.map((entry) => entry.operation),
        GenerationOperation.values,
      );
      expect(
        report.operations.where((entry) => entry.implemented).single.operation,
        enabled,
      );
      for (final operation in GenerationOperation.values) {
        expect(report.implementsOperation(operation), operation == enabled);
      }
    }
    const unknown = GenerationCapabilities(host: 'Future host');
    expect(unknown.operations.any((entry) => entry.implemented), isFalse);
  });
  for (final report in [
    const GenerationCapabilities.macOS(),
    const GenerationCapabilities.unavailable('Windows'),
    const GenerationCapabilities(
      host: 'Starter-only reporting fixture',
      starterCreation: true,
      starterVerification: true,
      webPreview: true,
      processCleanup: true,
    ),
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
      expect(
        find.text(
          'Candidate confinement: ${report.candidateConfinement ? 'Implemented path' : 'Unavailable / unverified'}',
        ),
        findsOneWidget,
      );
      final cleanup = find.textContaining('Process cleanup:');
      await tester.ensureVisible(cleanup);
      await tester.pumpAndSettle();
      expect(cleanup, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

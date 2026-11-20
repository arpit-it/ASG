// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_repository_context.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_advisory_request_test.dart' as legacy;
import 'imported_source_context_test.dart' as source;

void main() {
  test('advisory context API preserves exact pre-change legacy request and context identity', () {
    final request = legacy.prepare();
    expect(
      request.digest,
      '3da7af058494f289036bd4fa9acbae5b88a717f591f36b6bdeb48b8f8c321bec',
    );
    expect(
      request.contextDigest,
      'c80c69217fd617297c0f959fdb09a0e5fbd6a528777d16ab6a6c6e28713eec0b',
    );
    final ImportedRepositoryContext context = request.context;
    expect(context.includesSource, false);
    expect(context.sourceVerified, false);
  });
  test('typed source and document captures retain separate payloads and literal immutable attribution', () {
    const text = '\ufeffUntrusted [link](file://private)\r\n';
    final ImportedRepositoryContext document = legacy.capture(text);
    final ImportedRepositoryContext sources = source.capture(text: text);
    expect(document.includesSource, false);
    expect(sources.includesSource, true);
    expect(
      jsonDecode(document.recordJson)['scope'],
      'captured-imported-document-context',
    );
    expect(
      jsonDecode(sources.recordJson)['scope'],
      'captured-imported-source-context',
    );
    expect(document.capturedFiles.single.path, 'AGENTS.md');
    expect(sources.capturedFiles.single.path, 'lib/main.dart');
    for (final context in [document, sources]) {
      expect(context.capturedFiles.single.text, text);
      expect(context.capturedFiles.single.byteLength, utf8.encode(text).length);
      expect(() => context.capturedFiles.clear(), throwsUnsupportedError);
      expect(context.sourceVerified, false);
    }
  });
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/html/html_source_proposer.dart';
import 'package:asg/services/model_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class Provider implements ModelProvider {
  final stream = StreamController<String>();
  Completer<void>? cleanup;
  int cancellations = 0;
  bool failCleanup = false;
  String? prompt;
  @override
  Stream<String> generate(String prompt) {
    this.prompt = prompt;
    return stream.stream;
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    await cleanup?.future;
    if (failCleanup) throw StateError('Cleanup failed');
  }
}

void main() {
  const config = LocalModelConfig();
  const files = {
    'index.html': '<main>Hello</main>',
    'styles.css': 'main { color: navy; }',
  };
  String response([Map<String, Object?> extra = const {}]) => jsonEncode({
    'summary': ' Greeting ',
    'files': {...files, ...extra},
  });
  test('immutable complete sources and optional JavaScript', () {
    for (final extra in [
      <String, Object?>{},
      {'app.js': 'alert("hi")'},
    ]) {
      final p = HtmlSourceProposal.decode(response(extra));
      expect(p.summary, 'Greeting');
      expect(p.files['index.html'], files['index.html']);
      expect(() => p.files.clear(), throwsUnsupportedError);
    }
  });
  final invalid = [
    '',
    '```json\n{}\n```',
    '[]',
    '{}',
    '{"summary":"x","summary":"y","files":{}}',
    '{"summary":"x","files":{"index.html":"a","index\\u002ehtml":"b","styles.css":"c"}}',
    jsonEncode({'summary': 'x', 'files': files, 'command': 'run'}),
    jsonEncode({'summary': ' ', 'files': files}),
    jsonEncode({
      'summary': 'x',
      'files': {'index.html': 'a'},
    }),
    for (final name in [
      '../index.html',
      '/index.html',
      'INDEX.HTML',
      'package.json',
    ])
      response({name: 'bad'}),
    response({'app.js': null}),
    response({'styles.css': ''}),
    response({'styles.css': 'a\u0000b'}),
    response({'styles.css': 'é' * 32001}),
    response({'styles.css': 'a' * 64001}),
    response({'styles.css': 'a' * 64000, 'index.html': 'a' * 64000}),
  ];
  for (var i = 0; i < invalid.length; i++) {
    test(
      'reject malformed, duplicate, path or bounds case $i',
      () => expect(
        () => HtmlSourceProposal.decode(invalid[i]),
        throwsFormatException,
      ),
    );
  }
  test('streamed complete artifact and cleanup', () async {
    final p = Provider();
    final s = HtmlSourceProposer(createProvider: (_) => p);
    final pending = s.propose(config: config, instruction: 'Café landing page');
    final json = response();
    p.stream.add(json.substring(0, 20));
    p.stream.add(json.substring(20));
    await p.stream.close();
    expect((await pending).files, files);
    expect(p.cancellations, 1);
    expect(p.prompt, contains('Café landing page'));
  });
  test('invalid instructions do not allocate providers', () async {
    var n = 0;
    final s = HtmlSourceProposer(
      createProvider: (_) {
        n++;
        return Provider();
      },
    );
    for (final text in ['', ' ', 'a' * 8001]) {
      await expectLater(
        s.propose(config: config, instruction: text),
        throwsFormatException,
      );
    }
    expect(n, 0);
  });
  test('cancel retains stream ownership and rejects late results', () async {
    final p = Provider();
    final s = HtmlSourceProposer(createProvider: (_) => p);
    final pending = s.propose(config: config, instruction: 'Greeting');
    final assertion = expectLater(pending, throwsStateError);
    await s.cancel();
    await expectLater(
      s.propose(config: config, instruction: 'Again'),
      throwsStateError,
    );
    p.stream.add(response());
    await p.stream.close();
    await assertion;
    expect(p.cancellations, 2);
  });
  test(
    'cancel during cleanup rejects late success and overlapping requests',
    () async {
      final p = Provider()..cleanup = Completer();
      final s = HtmlSourceProposer(createProvider: (_) => p);
      final pending = s.propose(config: config, instruction: 'Greeting');
      final assertion = expectLater(pending, throwsStateError);
      p.stream.add(response());
      await p.stream.close();
      final cancelling = s.cancel();
      await expectLater(
        s.propose(config: config, instruction: 'Again'),
        throwsStateError,
      );
      p.cleanup!.complete();
      await cancelling;
      await assertion;
    },
  );
  for (final kind in [
    'malformed',
    'oversized',
    'multibyte',
    'transport',
    'cleanup',
  ]) {
    test('$kind failure cleans up and allows a settled retry', () async {
      var p = Provider();
      final s = HtmlSourceProposer(createProvider: (_) => p);
      final pending = s.propose(config: config, instruction: 'Greeting');
      final assertion = expectLater(pending, throwsA(anything));
      if (kind == 'transport') {
        p.stream.addError(StateError('Transport failed'));
      } else {
        p.failCleanup = kind == 'cleanup';
        p.stream.add(switch (kind) {
          'malformed' => '{}',
          'oversized' => 'a' * 128001,
          'multibyte' => 'é' * 64001,
          _ => response(),
        });
      }
      await p.stream.close();
      await assertion;
      expect(p.cancellations, 1);
      p = Provider();
      final retry = s.propose(config: config, instruction: 'Retry');
      p.stream.add(response());
      await p.stream.close();
      expect((await retry).files, files);
    });
  }
}

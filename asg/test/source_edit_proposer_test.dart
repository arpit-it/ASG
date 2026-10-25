import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/source_edit_proposer.dart';

class FakeProvider implements ModelProvider {
  final stream = StreamController<String>();
  Completer<void>? cleanup;
  int cancellations = 0;
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
  }
}

void main() {
  const original = 'void main() {}';
  const replacement = 'void main() { print("Hello"); }';
  final originals = {'lib/main.dart': original};
  Map<String, Object> response({
    String path = 'lib/main.dart',
    String before = original,
    String after = replacement,
  }) => {
    'summary': 'Add greeting',
    'changes': [
      {'path': path, 'before': before, 'after': after},
    ],
  };

  test('proposal provides immutable full before/after review evidence', () {
    final result = SourceEditProposal.parse(response(), originals: originals);
    expect(result.changes.single.before, original);
    expect(result.changes.single.after, replacement);
    expect(() => result.changes.clear(), throwsUnsupportedError);
  });

  test('rejects paths outside existing Dart source scope', () {
    for (final path in [
      '../main.dart',
      '/lib/main.dart',
      'lib/../main.dart',
      'lib\\main.dart',
      'pubspec.yaml',
      'lib/a.dart\n',
      'lib/a%2fb.dart',
      'lib/.hidden.dart',
    ]) {
      expect(
        () => SourceEditProposal.parse(
          response(path: path),
          originals: {...originals, path: original},
        ),
        throwsFormatException,
        reason: path,
      );
    }
  });

  test('rejects new files', () {
    expect(
      () => SourceEditProposal.parse(
        response(path: 'lib/new.dart'),
        originals: originals,
      ),
      throwsFormatException,
    );
  });

  test('rejects stale, unchanged, empty and oversized replacements', () {
    for (final raw in [
      response(before: 'stale'),
      response(after: original),
      response(after: ' '),
      response(after: 'x' * 32001),
    ]) {
      expect(
        () => SourceEditProposal.parse(raw, originals: originals),
        throwsFormatException,
      );
    }
  });

  test('strict shape rejects duplicates, unknown keys and malformed data', () {
    final change = (response()['changes'] as List).single;
    for (final raw in [
      null,
      [],
      {'summary': 'a', 'changes': []},
      {...response(), 'command': 'execute'},
      {
        'summary': 'a',
        'changes': [change, change],
      },
      {
        'summary': 'a',
        'changes': [
          {...change as Map, 'op': 'write'},
        ],
      },
      {
        'summary': 'a',
        'changes': [1],
      },
      {'summary': 'a', 'changes': List.filled(9, change)},
      {...response(), 'summary': 'x' * 1001},
    ]) {
      expect(
        () => SourceEditProposal.parse(raw, originals: originals),
        throwsFormatException,
      );
    }
  });

  test(
    'streams JSON with an immutable snapshot and cleans transport',
    () async {
      final provider = FakeProvider();
      final proposer = SourceEditProposer(createProvider: (_) => provider);
      final mutable = {...originals};
      final future = proposer.propose(
        config: const LocalModelConfig(),
        instruction: 'Add greeting',
        originals: mutable,
      );
      mutable.clear();
      final json = jsonEncode(response());
      provider.stream.add(json.substring(0, 20));
      provider.stream.add(json.substring(20));
      await provider.stream.close();
      expect((await future).changes.single.after, replacement);
      expect(provider.prompt, contains(original));
      expect(provider.cancellations, 1);
    },
  );

  test(
    'cancellation rejects late results and blocks concurrent requests',
    () async {
      final provider = FakeProvider();
      final proposer = SourceEditProposer(createProvider: (_) => provider);
      Future<SourceEditProposal> start() => proposer.propose(
        config: const LocalModelConfig(),
        instruction: 'Change',
        originals: originals,
      );
      final future = start();
      final rejected = expectLater(future, throwsStateError);
      await expectLater(start(), throwsStateError);
      await proposer.cancel();
      provider.stream.add(jsonEncode(response()));
      await provider.stream.close();
      await rejected;
      expect(provider.cancellations, greaterThanOrEqualTo(1));
    },
  );

  test(
    'oversized output and malformed JSON fail with transport cleanup',
    () async {
      for (final value in ['x' * 128001, 'not json']) {
        final provider = FakeProvider();
        final proposer = SourceEditProposer(createProvider: (_) => provider);
        final future = proposer.propose(
          config: const LocalModelConfig(),
          instruction: 'Change',
          originals: originals,
        );
        final rejected = expectLater(future, throwsFormatException);
        provider.stream.add(value);
        await provider.stream.close();
        await rejected;
        expect(provider.cancellations, 1);
      }
    },
  );

  test('provider failure releases busy state for retry', () async {
    final provider = FakeProvider();
    var calls = 0;
    final proposer = SourceEditProposer(
      createProvider: (_) {
        if (calls++ == 0) throw StateError('Offline');
        return provider;
      },
    );
    Future<SourceEditProposal> start() => proposer.propose(
      config: const LocalModelConfig(),
      instruction: 'Change',
      originals: originals,
    );
    await expectLater(start(), throwsStateError);
    final retried = start();
    provider.stream.add(jsonEncode(response()));
    await provider.stream.close();
    expect((await retried).summary, 'Add greeting');
  });
  test(
    'cancellation during cleanup cannot publish a completed proposal',
    () async {
      final provider = FakeProvider()..cleanup = Completer<void>();
      final proposer = SourceEditProposer(createProvider: (_) => provider);
      final future = proposer.propose(
        config: const LocalModelConfig(),
        instruction: 'Change',
        originals: originals,
      );
      final rejected = expectLater(future, throwsStateError);
      provider.stream.add(jsonEncode(response()));
      await provider.stream.close();
      await Future<void>.delayed(Duration.zero);
      final cancelled = proposer.cancel();
      provider.cleanup!.complete();
      await cancelled;
      await rejected;
    },
  );

  test('duplicate JSON members reject without leaking busy state', () async {
    final valid = jsonEncode(response());
    final change = jsonEncode((response()['changes'] as List).single);
    const escapedPath = r'"pa\u0074h":"hidden",';
    final ambiguous = [
      '{"summary":"hidden",${valid.substring(1)}',
      '{"changes":[],${valid.substring(1)}',
      r'{"su\u006dmary":"hidden",' + valid.substring(1),
      for (final key in ['path', 'before', 'after'])
        '{"summary":"Review","changes":[{"$key":"hidden",'
            '${change.substring(1)}]}',
      '{"summary":"Review","changes":[{$escapedPath${change.substring(1)}]}',
    ];
    for (final raw in ambiguous) {
      final failed = FakeProvider();
      final retry = FakeProvider();
      var calls = 0;
      final proposer = SourceEditProposer(
        createProvider: (_) => calls++ == 0 ? failed : retry,
      );
      Future<SourceEditProposal> start() => proposer.propose(
        config: const LocalModelConfig(),
        instruction: 'Change',
        originals: originals,
      );
      final future = start();
      final rejected = expectLater(future, throwsFormatException);
      // Split even escaped key spellings across transport chunks.
      for (var i = 0; i < raw.length; i += 3) {
        failed.stream.add(raw.substring(i, (i + 3).clamp(0, raw.length)));
      }
      await failed.stream.close();
      await rejected;
      expect(failed.cancellations, 1);
      final retried = start();
      retry.stream.add(valid);
      await retry.stream.close();
      expect((await retried).changes.single.after, replacement);
      expect(retry.cancellations, 1);
    }
  });

  test('JSON-looking Dart strings and escaped keys remain valid', () async {
    const before = r'final text = "{\"path\": \"before\"}";';
    const after = r'final text = "{\"path\": \"after\"}";';
    final provider = FakeProvider();
    final proposer = SourceEditProposer(createProvider: (_) => provider);
    final future = proposer.propose(
      config: const LocalModelConfig(),
      instruction: 'Change text',
      originals: {'lib/main.dart': before},
    );
    provider.stream.add(
      jsonEncode(response(before: before, after: after))
          .replaceFirst('"summary"', r'"su\u006dmary"'),
    );
    await provider.stream.close();
    final result = await future;
    expect(result.changes.single.before, before);
    expect(result.changes.single.after, after);
  });

  test('invalid inputs do not create a provider', () async {
    final proposer = SourceEditProposer(
      createProvider: (_) => throw StateError('Must not create transport'),
    );
    for (final input in [
      <String, String>{},
      {'pubspec.yaml': 'text'},
      {'lib/main.dart': 'x' * 32001},
    ]) {
      await expectLater(
        proposer.propose(
          config: const LocalModelConfig(),
          instruction: 'Change',
          originals: input,
        ),
        throwsFormatException,
      );
    }
  });
}

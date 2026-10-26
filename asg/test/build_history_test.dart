import 'dart:convert';
import 'dart:io';

import 'package:asg/models/source_generation.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/record_storage.dart';
import 'package:sembast/sembast_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

GeneratedProject result(SourceGenerationPhase phase) => GeneratedProject(
  directory: '/recorded/artifact',
  sdk: '/sdk',
  python: 'python3',
  sources: {'lib/main.dart': 'a' * 64},
  phase: phase,
  steps: phase == SourceGenerationPhase.ready
      ? [
          for (final op in ['resolve', 'analyze', 'test', 'build'])
            GenerationStep(operation: op, exitCode: 0, output: 'ok'),
        ]
      : [],
  outputs: phase == SourceGenerationPhase.ready
      ? {'index.html': 'b' * 64, 'main.dart.js': 'c' * 64}
      : {},
);

class Records implements RecordStorage {
  final data = <String, String>{};
  bool fail = false;
  @override
  String? getString(String key) => data[key];
  @override
  Future<bool> setString(String key, String value) async {
    if (fail) return false;
    data[key] = value;
    return true;
  }
}

void main() {
  test(
    'terminal history survives native reopen with exact success and failure',
    () async {
      final directory = await Directory.systemTemp.createTemp('asg_history_');
      final path = '${directory.path}/records.db';
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var native = await databaseFactoryIo.openDatabase(path);
      var db = await StudioDatabase.migrate(native, prefs);
      try {
        var store = SourceGenerationStore(db);
        final success = result(SourceGenerationPhase.ready);
        final failure = result(SourceGenerationPhase.failed);
        await store.save('p', success);
        await store.save('p', success); // repeated publication is idempotent
        await store.save('p', failure);
        await native.close();
        native = await databaseFactoryIo.openDatabase(path);
        db = await StudioDatabase.migrate(native, prefs);
        store = SourceGenerationStore(db);
        expect(store.load('p')!.phase, SourceGenerationPhase.failed);
        final history = store.history('p');
        expect(history.length, 2);
        expect(history.first.project.toJson(), success.toJson());
        expect(history.last.project.toJson(), failure.toJson());
        expect(history.first.recordedAt!.isUtc, isTrue);
      } finally {
        await native.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('legacy preserved; failed write and corrupt journal never overwrite evidence', () async {
    final records = Records();
    final store = SourceGenerationStore(records);
    final legacy = jsonEncode(result(SourceGenerationPhase.generated).toJson());
    records.data['studio.generation.v1.p'] = legacy;
    expect(store.load('p')!.phase, SourceGenerationPhase.generated);
    expect(store.history('p'), isEmpty);
    await store.save('p', result(SourceGenerationPhase.ready));
    final before = records.data['studio.generation.v1.p'];
    records.fail = true;
    await expectLater(
      store.save('p', result(SourceGenerationPhase.failed)),
      throwsStateError,
    );
    expect(records.data['studio.generation.v1.p'], before);
    records.fail = false;
    records.data['studio.generation.v1.legacy'] = jsonEncode(
      result(SourceGenerationPhase.ready).toJson(),
    );
    await store.save('legacy', result(SourceGenerationPhase.failed));
    expect(store.history('legacy').first.recordedAt, isNull);
    expect(
      store.history('legacy').first.project.phase,
      SourceGenerationPhase.ready,
    );
    final corrupt = jsonDecode(before!) as Map<String, dynamic>;
    corrupt['buildHistory'] = [
      {'recordedAt': 'invalid'},
    ];
    records.data['studio.generation.v1.p'] = jsonEncode(corrupt);
    final preserved = records.data['studio.generation.v1.p'];
    expect(() => store.load('p'), throwsA(anything));
    await expectLater(
      store.save('p', result(SourceGenerationPhase.failed)),
      throwsA(anything),
    );
    expect(records.data['studio.generation.v1.p'], preserved);
  });
}

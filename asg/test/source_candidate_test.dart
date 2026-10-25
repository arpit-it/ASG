@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/source_candidate.dart';
import 'package:asg/services/source_candidate_native.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'approved_source_proposer_test.dart' show seed;
import 'planning_conversation_test.dart' show ControlledRecords, project;

void main() {
  late Directory base, original;
  late ControlledRecords records;
  late Map<String, String> hashes;
  const before = 'void main() {}\r\n';
  const after = 'void main() { /* hello 🌍 */ }\n';
  Future<void> write(String relative, List<int> bytes) async {
    final file = File(path.join(original.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    hashes[relative] = sha256.convert(bytes).toString();
  }

  GeneratedProject generated() => GeneratedProject(
    directory: original.path,
    sdk: '/sdk',
    python: 'python3',
    sources: hashes,
    outputs: {'index.html': 'a' * 64},
    steps: [
      const GenerationStep(operation: 'resolve', exitCode: 0, output: ''),
    ],
  );
  SourceEditProposal proposal({String originalText = before}) =>
      SourceEditProposal.parse(
        {
          'summary': 'Greeting',
          'changes': [
            {'path': 'lib/main.dart', 'before': originalText, 'after': after},
          ],
        },
        originals: {'lib/main.dart': originalText},
      );
  ApprovedSourceProposal evidence() => ApprovedSourceProposal(
    projectId: project.id,
    boardTaskId: 'Tanalyze',
    approval: PlanApprovalStore(records).load(project.id)!,
    proposal: proposal(),
  );
  Future<GeneratedProject> prepare({void Function()? active}) =>
      prepareSourceCandidate(
        project: project,
        generated: generated(),
        evidence: evidence(),
        records: records,
        parent: base.path,
        checkActive: active ?? () {},
      );
  Future<GeneratedProject> raw({
    GeneratedProject? saved,
    SourceEditProposal? change,
    String? parent,
  }) => prepareCandidateFiles(
    generated: saved ?? generated(),
    proposal: change ?? proposal(),
    parent: parent ?? base.path,
    authorizeWrite: () {},
  );
  setUp(() async {
    base = await Directory.systemTemp.createTemp('asg-candidate-test-');
    base = Directory(await base.resolveSymbolicLinks());
    original = await Directory(path.join(base.path, 'working')).create();
    records = ControlledRecords();
    await seed(records);
    hashes = {};
    await write('lib/main.dart', utf8.encode(before));
    await write('pubspec.yaml', utf8.encode('name: original\n'));
    await write('assets/data.bin', [0, 255, 127]);
    await write('.gitignore', utf8.encode('build/\n'));
    final input = GenerationInput(
      project,
      ApplicationStore(records).load(project).definition,
    );
    await write('assets/app.json', utf8.encode(input.applicationJson));
    await write('asg_project.json', utf8.encode(input.metadataJson));
    await Directory(path.join(original.path, 'build/web'))
        .create(recursive: true);
    await File(path.join(original.path, 'build/web/index.html'))
        .writeAsString('WORKING');
    await Directory(path.join(original.path, '.dart_tool')).create();
    await File(path.join(original.path, '.dart_tool/package_config.json'))
        .writeAsString('{}');
    await File(path.join(original.path, 'pubspec.lock')).writeAsString('lock');
  });
  tearDown(() async => base.delete(recursive: true));

  test('candidate copies exact bytes, preserves working output and starts unverified', () async {
    final writes = records.writes;
    final result = await prepare();
    expect(result.directory, isNot(original.path));
    expect(
      await File(path.join(result.directory, 'lib/main.dart')).readAsString(),
      after,
    );
    expect(
      await File(path.join(result.directory, 'assets/data.bin')).readAsBytes(),
      [0, 255, 127],
    );
    expect(
      await File(path.join(result.directory, 'pubspec.yaml')).readAsString(),
      'name: original\n',
    );
    expect(
      result.sources['lib/main.dart'],
      sha256.convert(utf8.encode(after)).toString(),
    );
    expect(result.sources['assets/data.bin'], hashes['assets/data.bin']);
    for (final ignored in ['build', '.dart_tool', 'pubspec.lock']) {
      expect(
        await FileSystemEntity.type(path.join(result.directory, ignored)),
        FileSystemEntityType.notFound,
      );
    }
    expect(result.steps, isEmpty);
    expect(result.outputs, isEmpty);
    expect(result.resolution, isEmpty);
    expect(result.phase, SourceGenerationPhase.generated);
    expect(result.approval!.matches(evidence().approval), isTrue);
    expect(result.tasks!.any((t) => t.boardTaskId == 'Tanalyze'), isTrue);
    expect(records.writes, writes);
    expect(
      await File(path.join(original.path, 'lib/main.dart')).readAsString(),
      before,
    );
    expect(
      await File(path.join(original.path, 'build/web/index.html'))
          .readAsString(),
      'WORKING',
    );
    expect((await prepare()).directory, isNot(result.directory));
  });

  test(
    'withdrawn and mismatched project/task evidence refuse before writes',
    () async {
      final valid = evidence();
      for (final bad in [
        ApprovedSourceProposal(
          projectId: 'other',
          boardTaskId: valid.boardTaskId,
          approval: valid.approval,
          proposal: valid.proposal,
        ),
        ApprovedSourceProposal(
          projectId: project.id,
          boardTaskId: 'unknown',
          approval: valid.approval,
          proposal: valid.proposal,
        ),
      ]) {
        await expectLater(
          prepareSourceCandidate(
            project: project,
            generated: generated(),
            evidence: bad,
            records: records,
            parent: base.path,
            checkActive: () {},
          ),
          throwsStateError,
        );
      }
      await PlanApprovalStore(records)
          .save(project, ConversationStore(records).load(project.id), false);
      await expectLater(
        prepareSourceCandidate(
          project: project,
          generated: generated(),
          evidence: valid,
          records: records,
          parent: base.path,
          checkActive: () {},
        ),
        throwsStateError,
      );
      expect(base.listSync().length, 1);
    },
  );

  test(
    'changed missing unrecorded and stale before text refuse without candidate',
    () async {
      final saved = generated();
      final file = File(path.join(original.path, 'lib/main.dart'));
      await file.writeAsString('changed');
      await expectLater(raw(saved: saved), throwsStateError);
      await file.delete();
      await expectLater(raw(saved: saved), throwsStateError);
      await file.writeAsString(before);
      final extra = File(path.join(original.path, 'unexpected.txt'));
      await extra.writeAsString('extra');
      await expectLater(raw(saved: saved), throwsStateError);
      await extra.delete();
      await expectLater(
        raw(
          saved: saved,
          change: proposal(originalText: 'stale'),
        ),
        throwsStateError,
      );
      expect(base.listSync().length, 1);
    },
  );

  test('linked source root and candidate parent refuse', () async {
    final file = File(path.join(original.path, 'lib/main.dart'));
    final external = await File(path.join(base.path, 'external.dart'))
        .writeAsString(before);
    await file.delete();
    await Link(file.path).create(external.path);
    await expectLater(raw(), throwsStateError);
    await Link(file.path).delete();
    await file.writeAsString(before);
    final alias = await Link(path.join(base.path, 'alias'))
        .create(original.path);
    await expectLater(
      raw(
        saved: GeneratedProject(
          directory: alias.path,
          sdk: '/sdk',
          python: 'python3',
          sources: hashes,
        ),
      ),
      throwsStateError,
    );
    for (final parent in [
      original.path,
      path.join(original.path, 'lib'),
      alias.path,
    ]) {
      await expectLater(raw(parent: parent), throwsStateError);
    }
  });

  test('unsafe manifests, per-file and aggregate limits refuse', () async {
    for (final key in [
      '../escape',
      '/absolute',
      'lib/../../escape',
      '.git/config',
      'build/main.dart',
    ]) {
      await expectLater(
        raw(
          saved: GeneratedProject(
            directory: original.path,
            sdk: '/sdk',
            python: 'python3',
            sources: {key: 'a' * 64},
          ),
        ),
        throwsFormatException,
      );
    }
    await write('assets/large.bin', List.filled(512 * 1024 + 1, 0));
    await expectLater(raw(), throwsFormatException);
    await File(path.join(original.path, 'assets/large.bin')).delete();
    hashes.remove('assets/large.bin');
    for (var i = 0; i < 5; i++) {
      await write('assets/large$i.bin', List.filled(512 * 1024, 0));
    }
    await expectLater(raw(), throwsFormatException);
    expect(base.listSync().length, 1);
  });

  test(
    'cancellation during capture and writing never changes original',
    () async {
      for (final stopAt in [2, 5]) {
        var calls = 0;
        await expectLater(
          prepare(
            active: () {
              if (++calls == stopAt) throw StateError('Cancelled');
            },
          ),
          throwsStateError,
        );
      }
      expect(
        await File(path.join(original.path, 'lib/main.dart')).readAsString(),
        before,
      );
      expect(
        await File(path.join(original.path, 'build/web/index.html'))
            .readAsString(),
        'WORKING',
      );
    },
  );

  test('approval withdrawn across async capture refuses publication', () async {
    final pending = prepare();
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), false);
    await expectLater(pending, throwsStateError);
    expect(base.listSync().length, 1);
  });

  test(
    'final publication refusal reports the complete retained candidate path',
    () async {
      var successfulCalls = 0;
      await prepare(
        active: () {
          successfulCalls++;
        },
      );
      final existing = base.listSync().map((entry) => entry.path).toSet();
      var calls = 0;
      Object? failure;
      try {
        await prepare(
          active: () {
            if (++calls == successfulCalls) {
              throw StateError('Publication cancelled');
            }
          },
        );
      } catch (error) {
        failure = error;
      }
      final retained = base
          .listSync()
          .where((entry) => !existing.contains(entry.path))
          .single;
      expect(failure, isA<StateError>());
      expect(failure.toString(), contains(retained.path));
      expect(failure.toString(), contains('Publication cancelled'));
      expect(
        await File(path.join(retained.path, 'lib/main.dart')).readAsString(),
        after,
      );
      expect(
        await File(path.join(original.path, 'lib/main.dart')).readAsString(),
        before,
      );
      expect(
        await File(path.join(original.path, 'build/web/index.html'))
            .readAsString(),
        'WORKING',
      );
    },
  );

  test(
    'wrong generated project inputs and approval changes during writing refuse',
    () async {
      final correct = hashes['asg_project.json']!;
      hashes['asg_project.json'] = 'a' * 64;
      await expectLater(prepare(), throwsStateError);
      hashes['asg_project.json'] = correct;
      var calls = 0;
      await expectLater(
        prepare(
          active: () {
            if (++calls == 6) {
              records.values.remove('studio.planApproval.v1.${project.id}');
            }
          },
        ),
        throwsStateError,
      );
      expect(
        await File(path.join(original.path, 'lib/main.dart')).readAsString(),
        before,
      );
      expect(
        await File(path.join(original.path, 'build/web/index.html'))
            .readAsString(),
        'WORKING',
      );
    },
  );
}

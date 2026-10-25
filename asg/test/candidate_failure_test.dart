import 'dart:convert';
import 'dart:io';

import 'package:asg/models/candidate_failure.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

GeneratedProject failure({
  String operation = 'analyze',
  int exitCode = 1,
  bool cancelled = false,
  bool timedOut = false,
  bool outputLimitExceeded = false,
}) {
  const operations = ['resolve', 'analyze', 'test', 'build'];
  return GeneratedProject(
    directory: '/candidate',
    sdk: '/sdk',
    python: 'python3',
    sources: {'lib/main.dart': 'a' * 64},
    confined: true,
    checkpointVersion: 1,
    phase: SourceGenerationPhase.failed,
    steps: [
      for (final earlier in operations.take(operations.indexOf(operation)))
        GenerationStep(operation: earlier, exitCode: 0, output: 'passed'),
      GenerationStep(
        operation: operation,
        exitCode: exitCode,
        output: 'actual fixture diagnostic\nline 2',
        cancelled: cancelled,
        timedOut: timedOut,
        outputLimitExceeded: outputLimitExceeded,
      ),
    ],
  );
}

CandidateFailure? diagnose(GeneratedProject value) =>
    CandidateFailure.inspect(value, active: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'only terminal source-check exits supply possible repair diagnostics',
    () {
      for (final operation in ['analyze', 'test', 'build']) {
        final candidate = failure(operation: operation, exitCode: 65);
        final diagnosis = diagnose(candidate)!;
        expect(diagnosis.kind, CandidateFailureKind.sourceCheckFailure);
        expect(diagnosis.step, same(candidate.steps.last));
        expect(diagnosis.message, contains('$operation exited 65'));
        expect(diagnosis.message, contains('source cause is not established'));
        expect(diagnosis.step!.output, contains('line 2'));
        final reopened = GeneratedProject.fromJson(
          jsonDecode(jsonEncode(candidate.toJson())) as Map<String, dynamic>,
        );
        expect(diagnose(reopened)!.message, diagnosis.message);
        expect(reopened.toJson(), candidate.toJson());
      }
    },
  );

  test(
    'resolve, cancellation, resource limits and signals do not blame source',
    () {
      final cases = <GeneratedProject, CandidateFailureKind>{
        failure(operation: 'resolve'): CandidateFailureKind.dependencyFailure,
        failure(cancelled: true, timedOut: true, outputLimitExceeded: true):
            CandidateFailureKind.cancelled,
        failure(exitCode: 0, timedOut: true): CandidateFailureKind.timeout,
        failure(exitCode: 0, outputLimitExceeded: true):
            CandidateFailureKind.outputLimit,
        failure(exitCode: -9): CandidateFailureKind.terminated,
      };
      for (final entry in cases.entries) {
        final diagnosis = diagnose(entry.key)!;
        expect(diagnosis.kind, entry.value);
        expect(diagnosis.step!.exitCode, entry.key.steps.last.exitCode);
      }
    },
  );

  test(
    'pending, runner, validation and interrupted states never invent exits',
    () {
      final prefix = failure().copy(steps: [failure().steps.first]);
      final pending = prefix.copy(pendingOperation: 'analyze');
      expect(diagnose(pending)!.kind, CandidateFailureKind.uncertainExecution);
      expect(diagnose(pending)!.step, isNull);
      expect(
        diagnose(pending.copy(failedOperation: 'analyze'))!.kind,
        CandidateFailureKind.uncertainExecution,
      );
      expect(
        diagnose(prefix.copy(failedOperation: 'analyze'))!.kind,
        CandidateFailureKind.runnerOrValidation,
      );
      expect(diagnose(prefix)!.kind, CandidateFailureKind.missingFailure);
      expect(
        diagnose(prefix.copy(phase: SourceGenerationPhase.verifying))!.kind,
        CandidateFailureKind.interrupted,
      );
      expect(CandidateFailure.inspect(pending, active: true), isNull);
    },
  );

  test('malformed, legacy and unconfined evidence fail closed', () {
    expect(
      diagnose(failure().copy(steps: failure().steps.reversed.toList()))!.kind,
      CandidateFailureKind.invalidEvidence,
    );
    expect(
      diagnose(failure().copy(checkpointVersion: 0))!.kind,
      CandidateFailureKind.unsupportedEvidence,
    );
    final unconfined = failure().toJson()..remove('confinementVersion');
    expect(
      diagnose(GeneratedProject.fromJson(unconfined))!.kind,
      CandidateFailureKind.unsupportedEvidence,
    );
    expect(
      diagnose(failure().copy(pendingOperation: 'arbitrary-command'))!.kind,
      CandidateFailureKind.invalidEvidence,
    );
  });

  test(
    'prepared, active and complete successful checks have no failure diagnosis',
    () {
      final prepared = failure().copy(
        phase: SourceGenerationPhase.generated,
        steps: [],
      );
      expect(diagnose(prepared), isNull);
      final passed = failure(operation: 'build', exitCode: 0).copy(
        phase: SourceGenerationPhase.ready,
        outputs: {'index.html': 'a' * 64, 'main.dart.js': 'b' * 64},
      );
      expect(diagnose(passed), isNull);
      expect(CandidateFailure.inspect(failure(), active: true), isNull);
      expect(
        diagnose(failure(exitCode: 0))!.kind,
        CandidateFailureKind.missingFailure,
      );
    },
  );

  test(
    'actual native database reopen preserves diagnosis and working record',
    () async {
      SharedPreferences.setMockInitialValues({});
      final temporary = await Directory.systemTemp.createTemp('asg-diagnosis-');
      try {
        final path = '${temporary.path}/records.db';
        var database = await databaseFactoryIo.openDatabase(path);
        final preferences = await SharedPreferences.getInstance();
        var records = await StudioDatabase.migrate(database, preferences);
        final candidate = failure(operation: 'test');
        const workingKey = 'studio.lastProject.v1';
        await records.setString(workingKey, 'working-pointer-unchanged');
        var store = SourceGenerationStore(
          records,
          prefix: 'studio.sourceCandidate.v1.',
        );
        await store.save('p', candidate);
        final raw = records.getString('studio.sourceCandidate.v1.p');
        await database.close();
        database = await databaseFactoryIo.openDatabase(path);
        try {
          records = await StudioDatabase.migrate(database, preferences);
          store = SourceGenerationStore(
            records,
            prefix: 'studio.sourceCandidate.v1.',
          );
          expect(
            diagnose(store.load('p')!)!.message,
            diagnose(candidate)!.message,
          );
          expect(records.getString('studio.sourceCandidate.v1.p'), raw);
          expect(records.getString(workingKey), 'working-pointer-unchanged');
        } finally {
          await database.close();
        }
      } finally {
        await temporary.delete(recursive: true);
      }
    },
  );
}

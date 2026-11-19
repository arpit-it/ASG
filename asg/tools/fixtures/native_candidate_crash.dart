// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

// Disposable native fixture; never referenced by production main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:asg/models/candidate_operation_receipt.dart';
import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_execution_checkpoint.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_session_admission.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/plan_approval.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/candidate_receipt_native.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/views/source_candidate_view.dart';

const bundle = 'com.arsinha.asg.restartfixture';
const operations = ['resolve', 'analyze', 'test', 'build'];

String digest(String text) => sha256.convert(utf8.encode(text)).toString();

// Fixture fault injection stops before the database transaction begins.
final class StopCommitBarrier implements ConditionalRecordStorage {
  StopCommitBarrier(this.delegate);
  final ConditionalRecordStorage delegate;
  bool reached = false;
  final pending = Completer<void>();
  @override
  String? getString(String key) => delegate.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      delegate.setString(key, value);
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    if (updates.keys.any(
      (key) => key.startsWith(CandidateVerificationStore.stopPrefix),
    )) {
      if (updates.length != 1) throw StateError('Unexpected Stop transaction');
      authorize();
      reached = true;
      await pending.future; // Host crashes only this fixture; never released.
      throw StateError('Fixture Stop barrier must never resume');
    }
    await delegate.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
  }
}

// Refuse one publication before its atomic transaction; never changes records.
final class PromotionCommitFault implements ConditionalRecordStorage {
  PromotionCommitFault(this.delegate);
  final ConditionalRecordStorage delegate;
  bool refuse = true, reached = false;
  Future<void> Function()? afterPublicationCommit;
  @override
  String? getString(String key) => delegate.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      delegate.setString(key, value);
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    if (refuse &&
        updates.keys.any(
          (key) => key.startsWith('studio.generationPrevious.v1.'),
        )) {
      authorize();
      reached = true;
      throw StateError('Fixture publication refusal');
    }
    await delegate.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
    if (updates.keys.any(
      (key) => key.startsWith('studio.generationPrevious.v1.'),
    )) {
      await afterPublicationCommit?.call();
    }
  }
}

// Pause only the selected-session startup transaction, before any database write.
final class AdmissionCommitBarrier implements ConditionalRecordStorage {
  AdmissionCommitBarrier(this.delegate);
  final ConditionalRecordStorage delegate;
  Future<void> Function()? onAdmission;
  @override
  String? getString(String key) => delegate.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      delegate.setString(key, value);
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    if (onAdmission != null &&
        updates.keys.any((key) => key.startsWith(AgentSession.prefix)) &&
        updates.keys.any(
          (key) => key.startsWith('studio.candidateChecks.v1.'),
        )) {
      authorize();
      await onAdmission!();
      throw StateError('Admission crash barrier must never return');
    }
    await delegate.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
  }
}

final class SignalledFixtureHost extends NativeGenerationHost {
  SignalledFixtureHost({
    required super.receiptFiles,
    required super.runOperation,
    super.loadAsset,
    this.onPrepare,
    this.onCommand,
  });
  final void Function()? onPrepare, onCommand;
  Uri? preparedPreview;
  @override
  Future<Uri> startPreview(GeneratedProject project) async {
    final uri = await super.startPreview(project);
    preparedPreview = uri;
    return uri;
  }

  @override
  Future<GenerationStep> runFlutterOperation(
    GeneratedProject project,
    String operation, {
    Future<void> Function()? beforeStart,
    String? receiptDirectory,
  }) async {
    onCommand?.call();
    return super.runFlutterOperation(
      project,
      operation,
      beforeStart: beforeStart,
      receiptDirectory: receiptDirectory,
    );
  }

  @override
  Future<void> prepareCandidateReceipts(
    CandidateVerificationRun run,
    void Function() authorize,
  ) async {
    onPrepare?.call();
    await super.prepareCandidateReceipts(run, authorize);
  }

  bool stopSignalled = false;
  @override
  void cancelVerification() {
    super.cancelVerification();
    stopSignalled = true;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var stage = 'preflight';
  try {
    if (!Platform.isMacOS) throw StateError('Mac fixture only.');
    final executable = File(Platform.resolvedExecutable);
    final identity = await Process.run('/usr/bin/plutil', [
      '-extract',
      'CFBundleIdentifier',
      'raw',
      '-o',
      '-',
      path.join(executable.parent.parent.path, 'Info.plist'),
    ]);
    if (identity.exitCode != 0 || '${identity.stdout}'.trim() != bundle) {
      throw StateError('Fixture bundle required.');
    }
    final root = Directory(
      Platform.environment['ASG_CANDIDATE_CRASH_ROOT'] ?? '',
    );
    final canonical = await root.resolveSymbolicLinks();
    if (canonical != path.normalize(root.absolute.path) ||
        !path.isWithin(
          await Directory.systemTemp.resolveSymbolicLinks(),
          canonical,
        ) ||
        !path.basename(canonical).startsWith('asg-candidate-crash-') ||
        (await root.stat()).mode & 0x3f != 0) {
      throw StateError('Private canonical fixture root required.');
    }
    final challenge = File(path.join(canonical, 'challenge.json'));
    if (await FileSystemEntity.isLink(challenge.path) ||
        await challenge.length() > 4096) {
      throw StateError('Invalid challenge.');
    }
    final input = jsonDecode(await challenge.readAsString());
    if (input is! Map<String, dynamic> ||
        input.length != 17 ||
        input['nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(input['nonce'] as String) ||
        ![1, 2, 3, 4, 5].contains(input['launch']) ||
        input['sdk'] is! String ||
        input['sessionCancelUnknown'] is! bool ||
        (input['sessionCancelUnknown'] == true &&
            input['sessionCancelActive'] != true) ||
        input['sessionCancelActive'] is! bool ||
        (input['sessionCancelActive'] == true &&
            input['sessionCancel'] != true) ||
        input['sessionCancel'] is! bool ||
        (input['sessionCancel'] == true &&
            (input['sessionBound'] != true ||
                input['admissionCrash'] == true)) ||
        input['sessionBound'] is! bool ||
        input['admissionCrash'] is! bool ||
        (input['admissionCrash'] == true && input['sessionBound'] != true) ||
        (input['sessionBound'] == true &&
            (input['stop'] != true ||
                input['operation'] != 'test' ||
                ['precommit', 'uncertain'].any((key) => input[key] != false) ||
                ([
                      'running',
                      'acknowledge',
                      'retry',
                      'promote',
                      'promotionCrash',
                    ].any((key) => input[key] == true) &&
                    !(input['running'] == true &&
                        input['acknowledge'] == true &&
                        input['retry'] == true &&
                        input['admissionCrash'] == false &&
                        input['sessionCancel'] == false)))) ||
        input['stop'] is! bool ||
        input['precommit'] is! bool ||
        input['running'] is! bool ||
        input['uncertain'] is! bool ||
        input['acknowledge'] is! bool ||
        input['retry'] is! bool ||
        input['promote'] is! bool ||
        input['promotionCrash'] is! bool ||
        (input['promotionCrash'] == true && input['promote'] != true) ||
        (input['promote'] == true && input['retry'] != true) ||
        (input['launch'] == 5 && input['promote'] != true) ||
        (input['retry'] == true && input['acknowledge'] != true) ||
        (input['launch'] == 4 && input['retry'] != true) ||
        (input['launch'] == 3 && input['acknowledge'] != true) ||
        (input['acknowledge'] == true &&
            (input['running'] != true || input['uncertain'] == true)) ||
        (input['uncertain'] == true && input['running'] != true) ||
        (input['running'] == true &&
            (input['stop'] != true ||
                input['precommit'] == true ||
                input['operation'] != 'test')) ||
        (input['precommit'] == true && input['stop'] != true) ||
        !operations.contains(input['operation'])) {
      throw StateError('Invalid challenge schema.');
    }
    final nonce = input['nonce'] as String;
    final launch = input['launch'] as int;
    final operation = input['operation'] as String;
    final targetIndex = operations.indexOf(operation);
    final sessionCancel = input['sessionCancel'] as bool;
    final sessionCancelActive = input['sessionCancelActive'] as bool;
    final sessionCancelUnknown = input['sessionCancelUnknown'] as bool;
    final sessionBound = input['sessionBound'] as bool;
    final admissionCrash = input['admissionCrash'] as bool;
    final stop = input['stop'] as bool;
    final precommit = input['precommit'] as bool;
    final running = input['running'] as bool;
    final uncertain = input['uncertain'] as bool;
    final acknowledge = input['acknowledge'] as bool;
    final retry = input['retry'] as bool;
    final promote = input['promote'] as bool;
    final promotionCrash = input['promotionCrash'] as bool;
    final acknowledged = acknowledge && launch >= 3;
    final sdk = await Directory(input['sdk'] as String).resolveSymbolicLinks();
    final support = await getApplicationSupportDirectory();
    if (path.basename(support.path) != bundle ||
        await support.resolveSymbolicLinks() !=
            path.normalize(support.absolute.path)) {
      throw StateError('Fixture support required.');
    }
    stage = 'database';
    final records = await StudioDatabase.open();
    final barrier = StopCommitBarrier(records);
    final admissionBarrier = AdmissionCommitBarrier(records);
    final controllerRecords = admissionCrash && launch == 1
        ? admissionBarrier
        : precommit && launch == 1
        ? barrier
        : records;
    final projectId = 'restart-$nonce';
    final checks = CandidateVerificationStore(records, projectId);
    final workingKey = 'studio.generation.v1.$projectId';
    final candidate = Directory(path.join(canonical, 'candidate'));
    final working = File(path.join(canonical, 'working', 'index.html'));
    var approval = PlanApproval(
      messageIndex: 0,
      content: 'Disposable fixed verification fixture',
      context: nonce,
      approved: true,
      recordedAt: DateTime.utc(2026),
    );
    final project = StudioProject(
      id: projectId,
      name: 'Disposable crash fixture',
      description: '',
      type: 'Flutter',
      platforms: const ['web'],
      location: candidate.path,
    );
    final receiptRoot = Directory(
      path.join(support.path, 'fixture-receipts-$nonce'),
    );
    final receipts = CandidateReceiptFiles(root: () async => receiptRoot);
    var receiptPreparations = 0, commandEntries = 0;
    final host = SignalledFixtureHost(
      receiptFiles: receipts,
      runOperation: null,
      onPrepare: launch == 1 ? null : () => receiptPreparations++,
      onCommand: launch == 1 ? null : () => commandEntries++,
    );
    AgentSession? selectedSession, initialSessionSelection;
    Map<String, Object?>? initialCancellationOutput;
    Future<Map<String, Object?>> outputState() async => {
      'working': digest(records.getString(workingKey)!),
      'output': digest(await working.readAsString()),
      'workingSource': digest(
        await File(path.join(working.parent.path, 'lib', 'main.dart'))
            .readAsString(),
      ),
      'sources': digest(
        jsonEncode(
          await NativeGenerationHost.fingerprints(candidate.path, source: true),
        ),
      ),
    };
    Future<String> firstReceiptHash() async {
      final observed = await receipts.read(checks.load().runs.single);
      final expected = sessionCancelUnknown
          ? operations.take(2).toList()
          : sessionCancelActive
          ? operations.take(3).toList()
          : ['resolve'];
      if (jsonEncode(observed.map((item) => item.operation.name).toList()) !=
              jsonEncode(expected) ||
          observed.any(
            (item) => item.result.exitCode != 0 || item.result.cancelled,
          )) {
        throw StateError(
          'Only the validated first receipt may be fingerprinted',
        );
      }
      final directory =
          (await receiptRoot
                  .list(followLinks: false)
                  .where((entry) => entry is Directory)
                  .toList())
              .single;
      final evidence = <String, String>{};
      for (final name in [
        'context.json',
        for (final operation in expected) ...[
          '$operation.intent.json',
          '$operation.result.json',
        ],
        if (sessionCancelUnknown) 'test.intent.json',
      ]) {
        final file = File(path.join(directory.path, name));
        if (await FileSystemEntity.isLink(file.path) ||
            await file.length() > 256 * 1024 ||
            await file.resolveSymbolicLinks() != file.absolute.path) {
          throw StateError('Invalid first receipt fingerprint input');
        }
        evidence[name] = await file.readAsString();
      }
      return digest(jsonEncode(evidence));
    }

    Future<String> activeBoundaryHash() async {
      final file = File(path.join(canonical, 'active-cancellation.json'));
      if (await FileSystemEntity.isLink(file.path) ||
          await file.length() > 65536 ||
          await file.resolveSymbolicLinks() != file.absolute.path) {
        throw StateError('Invalid active cancellation boundary');
      }
      final raw = await file.readAsString();
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['nonce'] != nonce ||
          value['dispatch'] != 'candidate-$projectId-1:3' ||
          value['beforeRevision'] != 1 ||
          value['afterRevision'] != 2 ||
          value['activeBeforeExit'] != true) {
        throw StateError('Active cancellation boundary identity mismatch');
      }
      const hashes = [
        'intentSha256',
        'contextSha256',
        'markerSha256',
        'sessionBeforeSha256',
        'sessionAfterSha256',
        'journalSha256',
        'executionSha256',
      ];
      if (value.length != 12 ||
          hashes.any(
            (key) =>
                value[key] is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(value[key] as String),
          )) {
        throw StateError('Incomplete active cancellation fingerprints');
      }
      final directory =
          (await receiptRoot
                  .list(followLinks: false)
                  .where((entry) => entry is Directory)
                  .toList())
              .single;
      final inputs = {
        'intentSha256': File(path.join(directory.path, 'test.intent.json')),
        'contextSha256': File(path.join(directory.path, 'context.json')),
        'markerSha256': File(
          path.join(candidate.path, 'build', 'running-$nonce'),
        ),
        'sessionBeforeSha256': File(
          path.join(canonical, 'admitted-session.json'),
        ),
      };
      for (final entry in inputs.entries) {
        if (await FileSystemEntity.isLink(entry.value.path) ||
            await entry.value.length() > 256 * 1024 ||
            await entry.value.resolveSymbolicLinks() !=
                entry.value.absolute.path ||
            digest(await entry.value.readAsString()) != value[entry.key]) {
          throw StateError('Active cancellation ancestry changed');
        }
      }
      final saved = AgentSessionStore(records, project).load('session-$nonce')!;
      if (digest(records.getString(saved.storageKey)!) !=
          value['sessionAfterSha256']) {
        throw StateError('Withdrawn session identity changed');
      }
      return digest(raw);
    }

    Future<String> publicationFaultHash() async {
      final fault = File(
        path.join(candidate.path, 'build', 'result-fault-$nonce'),
      );
      final directory =
          (await receiptRoot
                  .list(followLinks: false)
                  .where((entry) => entry is Directory)
                  .toList())
              .single;
      if (await FileSystemEntity.isLink(fault.path) ||
          await fault.length() > 64 ||
          await fault.resolveSymbolicLinks() != fault.absolute.path ||
          await fault.readAsString() != nonce ||
          await FileSystemEntity.type(
                path.join(directory.path, 'test.result.json'),
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
        throw StateError('Unknown result publication boundary missing');
      }
      return digest(await fault.readAsString());
    }

    Future<Map<String, Object?>?> sessionProof() async {
      if (!sessionBound || retry) return null;
      final saved = AgentSessionStore(records, project).load('session-$nonce');
      if (saved == null ||
          saved.cancellationRequested != sessionCancel ||
          saved.revision !=
              (sessionCancel
                  ? 2
                  : admissionCrash
                  ? 0
                  : 1) ||
          saved.dispatches.length != (admissionCrash ? 0 : 1) ||
          (!admissionCrash &&
              (saved.dispatches.single.boardTaskId != 'Tanalyze' ||
                  saved.dispatches.single.dispatchId !=
                      'candidate-$projectId-1:3'))) {
        throw StateError('Session admission evidence mismatch');
      }
      final journal = records.getString(checks.key);
      final currentCandidate = records.getString(checks.candidateKey);
      final execution = records.getString(
        'studio.agentExecution.v1.candidate-$projectId-1',
      );
      if (admissionCrash &&
          (journal != null ||
              currentCandidate != null ||
              execution != null ||
              (await receiptRoot.exists() &&
                  await receiptRoot.list().isEmpty == false))) {
        throw StateError(
          'Uncommitted admission left startup records or receipts',
        );
      }
      if (admissionCrash) {
        for (final operation in operations) {
          if (await File(path.join(canonical, '$operation-dispatched'))
              .exists()) {
            throw StateError('Pre-admission command entry observed');
          }
        }
      }
      return {
        'sessionId': saved.sessionId,
        'projectId': saved.projectId,
        'revision': saved.revision,
        'dispatchCount': saved.dispatches.length,
        'dispatchId': saved.dispatches.isEmpty
            ? null
            : saved.dispatches.single.dispatchId,
        'sessionSha256': digest(records.getString(saved.storageKey)!),
        'journalSha256': journal == null ? null : digest(journal),
        'candidateSha256': currentCandidate == null
            ? null
            : digest(currentCandidate),
        'executionSha256': execution == null ? null : digest(execution),
        if (sessionCancel) 'cancellationRequested': saved.cancellationRequested,
        if (sessionCancel) 'receiptSha256': await firstReceiptHash(),
        if (sessionCancelActive)
          'activeBoundarySha256': await activeBoundaryHash(),
        if (sessionCancelUnknown) ...{
          'publicationFaultSha256': await publicationFaultHash(),
          'testResultPresent': false,
        },
        'receiptPreparations': receiptPreparations,
        'commandEntries': commandEntries,
      };
    }

    Future<String> retryReceiptHash(CandidateVerificationRun run) async {
      final observed = await receipts.read(run);
      final expected = operations.take(run.number == 1 ? 3 : 4).toList();
      if (![1, 2].contains(run.number) ||
          jsonEncode(
                observed.map((receipt) => receipt.operation.name).toList(),
              ) !=
              jsonEncode(expected)) {
        throw StateError('Complete retry receipt evidence missing');
      }
      for (var index = 0; index < observed.length; index++) {
        final result = observed[index].result;
        final stopped = run.number == 1 && index == 2;
        if (result.exitCode != (stopped ? -1 : 0) ||
            result.cancelled != stopped ||
            result.timedOut ||
            result.outputLimitExceeded) {
          throw StateError(
            'Retry receipt result disagrees with the actual fixed checks',
          );
        }
      }
      final prefix = '${digest(run.dispatchId!)}-';
      final directory =
          (await receiptRoot
                  .list(followLinks: false)
                  .where(
                    (entry) =>
                        entry is Directory &&
                        path.basename(entry.path).startsWith(prefix),
                  )
                  .toList())
              .single;
      final evidence = <String, String>{};
      for (final name in [
        'context.json',
        for (final receipt in observed) ...[
          '${receipt.operation.name}.intent.json',
          '${receipt.operation.name}.result.json',
        ],
      ]) {
        final file = File(path.join(directory.path, name));
        if (await FileSystemEntity.isLink(file.path) ||
            await file.length() > 256 * 1024 ||
            await file.resolveSymbolicLinks() != file.absolute.path) {
          throw StateError('Invalid retry receipt fingerprint input');
        }
        evidence[name] = await file.readAsString();
      }
      return digest(jsonEncode(evidence));
    }

    Future<Map<String, Object?>?> sessionRetryProof() async {
      if (!sessionBound || !retry) return null;
      final saved = AgentSessionStore(records, project).load('session-$nonce');
      if (saved == null ||
          saved.cancellationRequested ||
          ![1, 2].contains(saved.dispatches.length) ||
          saved.revision != saved.dispatches.length) {
        throw StateError('Invalid uncancelled retry session');
      }
      AgentSessionAdmission(records, project).requireApproval(saved);
      final journal = checks.load();
      if (journal.runs.length != saved.dispatches.length) {
        throw StateError('Retry session/run count changed');
      }
      for (var index = 0; index < saved.dispatches.length; index++) {
        final ref = saved.dispatches[index];
        if (ref.boardTaskId != 'Tanalyze' ||
            ref.runNumber != index + 1 ||
            ref.dispatchId != 'candidate-$projectId-${index + 1}:3' ||
            journal.runs[index].dispatchId != ref.dispatchId) {
          throw StateError('Retry session dispatch lineage changed');
        }
      }
      final first = journal.runs.first;
      final recovery = records.getString(
        '${CandidateVerificationStore.recoveryPrefix}${first.dispatchId}',
      );
      final secondExecution = records.getString(
        'studio.agentExecution.v1.candidate-$projectId-2',
      );
      return {
        'sessionId': saved.sessionId,
        'projectId': saved.projectId,
        'basisSha256': digest(
          jsonEncode({
            'sessionId': saved.sessionId,
            'projectId': saved.projectId,
            'approval': saved.approval.toJson(),
            'tasks': saved.tasks.toJson(),
          }),
        ),
        'sessionSha256': digest(records.getString(saved.storageKey)!),
        'revision': saved.revision,
        'dispatchCount': saved.dispatches.length,
        'dispatchIds': saved.dispatches.map((ref) => ref.dispatchId).toList(),
        'cancellationRequested': saved.cancellationRequested,
        'journalSha256': digest(records.getString(checks.key)!),
        'candidateSha256': digest(records.getString(checks.candidateKey)!),
        'firstRunSha256': digest(jsonEncode(first.toJson())),
        'firstExecutionSha256': digest(
          records.getString('studio.agentExecution.v1.candidate-$projectId-1')!,
        ),
        'firstReceiptSha256': await retryReceiptHash(first),
        'stopSha256': digest(
          records.getString(
            '${CandidateVerificationStore.stopPrefix}${first.dispatchId}',
          )!,
        ),
        'recoverySha256': recovery == null ? null : digest(recovery),
        'secondExecutionSha256': secondExecution == null
            ? null
            : digest(secondExecution),
        'secondReceiptSha256': journal.runs.length == 1
            ? null
            : await retryReceiptHash(journal.runs.last),
        if (promote) 'workingSha256': digest(records.getString(workingKey)!),
        if (promote)
          'previousSha256':
              records.getString('studio.generationPrevious.v1.$projectId') ==
                  null
              ? null
              : digest(
                  records.getString('studio.generationPrevious.v1.$projectId')!,
                ),
        if (promote)
          'workingPublished':
              journal.runs.length == 2 &&
              jsonEncode(
                    SourceGenerationStore(records).load(projectId)!.toJson(),
                  ) ==
                  jsonEncode(journal.runs.last.snapshot.toJson()),
        if (promote)
          'secondExecutionPhase': secondExecution == null
              ? null
              : AgentExecutionCheckpoint.fromJson(jsonDecode(secondExecution))
                    .phase
                    .name,
        'receiptPreparations': receiptPreparations,
        'commandEntries': commandEntries,
      };
    }

    String retryDigest(Map<String, Object?> proof) {
      final stable = Map<String, Object?>.from(proof)
        ..remove('receiptPreparations')
        ..remove('commandEntries');
      final entries = stable.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return digest(jsonEncode(Map.fromEntries(entries)));
    }

    Future<Map<String, Object?>> admissionState() async => {
      'sessionProof': await sessionProof(),
      'working': digest(records.getString(workingKey)!),
      'output': digest(await working.readAsString()),
      'sources': digest(
        jsonEncode(
          await NativeGenerationHost.fingerprints(candidate.path, source: true),
        ),
      ),
    };
    Future<void> admissionReport({required bool first}) async {
      final current = await admissionState();
      final baseline = File(path.join(canonical, 'before-admission.json'));
      if (first) {
        await baseline.create(exclusive: true);
        await baseline.writeAsString(jsonEncode(current), flush: true);
      } else if (jsonEncode(jsonDecode(await baseline.readAsString())) !=
          jsonEncode(current)) {
        throw StateError('Pre-admission reopen changed retained state');
      }
      runApp(
        const MaterialApp(
          home: Scaffold(body: Text('Disposable session admission: read only')),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      await report(
        canonical,
        launch,
        {
          'nonce': nonce,
          'dispatch': 'candidate-$projectId-1:3',
          'operation': operation,
          'completedOperations': <String>[],
          'stopRequested': stop,
          'precommit': precommit,
          'running': running,
          'uncertain': uncertain,
          'acknowledge': acknowledge,
          'retry': retry,
          'promote': promote,
          'promotionCrash': promotionCrash,
          'readyForCrash': first,
          'startupUnchanged': true,
          'workingUnchanged': true,
          'sourcesUnchanged': true,
          'viewRendered': true,
        },
        sessionBound: true,
        admissionCrash: true,
        sessionProof: await sessionProof(),
      );
    }

    Future<void> cancellationReport(
      SourceCandidateController controller, {
      required bool first,
    }) async {
      final run = checks.load().runs.single;
      final snapshot = run.snapshot;
      final retained = await receipts.read(run);
      final expected = sessionCancelUnknown
          ? operations.take(2).toList()
          : sessionCancelActive
          ? operations.take(3).toList()
          : ['resolve'];
      if (run.finished != !sessionCancelUnknown ||
          snapshot.phase != SourceGenerationPhase.failed ||
          snapshot.pendingOperation != (sessionCancelUnknown ? 'test' : '') ||
          (sessionCancelUnknown && snapshot.failedOperation != 'test') ||
          jsonEncode(snapshot.steps.map((item) => item.operation).toList()) !=
              jsonEncode(expected) ||
          snapshot.steps.any((item) => item.exitCode != 0 || item.cancelled) ||
          jsonEncode(retained.map((item) => item.operation.name).toList()) !=
              jsonEncode(expected) ||
          retained.any(
            (item) => item.result.exitCode != 0 || item.result.cancelled,
          ) ||
          controller.savedExecutionFor(run)?.phase.name !=
              (sessionCancelUnknown ? 'executing' : 'verifying') ||
          controller.canPromote ||
          checks.stopRequestFor(run) != null) {
        throw StateError(
          'Session cancellation did not retain only the actual first exit',
        );
      }
      for (final operation in operations.skip(sessionCancelActive ? 3 : 1)) {
        if (await File(path.join(canonical, '$operation-dispatched'))
            .exists()) {
          throw StateError(
            'A later command entered after session cancellation',
          );
        }
      }
      final proof = (await sessionProof())!;
      final output = await outputState();
      final stableProof = Map<String, Object?>.from(proof)
        ..remove('receiptPreparations')
        ..remove('commandEntries');
      final current = {'sessionProof': stableProof, 'outputState': output};
      final baseline = File(path.join(canonical, 'cancelled-state.json'));
      if (first) {
        if (jsonEncode(initialCancellationOutput) != jsonEncode(output)) {
          throw StateError(
            'Session cancellation changed source or prior working output',
          );
        }
        await baseline.create(exclusive: true);
        await baseline.writeAsString(jsonEncode(current), flush: true);
      } else if (jsonEncode(jsonDecode(await baseline.readAsString())) !=
          jsonEncode(current)) {
        throw StateError('Cancelled session reopen changed retained evidence');
      }
      runApp(MaterialApp(home: SourceCandidateView(controller: controller)));
      await WidgetsBinding.instance.endOfFrame;
      await report(
        canonical,
        launch,
        {
          'nonce': nonce,
          'dispatch': run.dispatchId,
          'operation': operation,
          'stopRequested': stop,
          'precommit': precommit,
          'running': running,
          'uncertain': uncertain,
          'acknowledge': acknowledge,
          'retry': retry,
          'promote': promote,
          'promotionCrash': promotionCrash,
          'completedOperations': expected,
          'receiptOperations': expected,
          'retainedExit': sessionCancelUnknown
              ? null
              : retained.last.result.exitCode,
          if (sessionCancelActive) ...{
            'activeBeforeExit': true,
            'runningMarker': true,
            'stopSignalled': false,
            'actualTestExit': sessionCancelUnknown
                ? null
                : retained.last.result.exitCode,
          },
          if (sessionCancelUnknown) ...{
            'privateFaultObserved': true,
            'cleanup': 'unknown',
            'acknowledgementPresent': checks.acknowledgementFor(run) != null,
            'failedOperation': snapshot.failedOperation,
          },
          'runFinished': run.finished,
          'candidatePhase': snapshot.phase.name,
          'pendingOperation': snapshot.pendingOperation,
          'executionPhase': controller.savedExecutionFor(run)!.phase.name,
          'candidateStopPresent': false,
          'promotionAllowed': controller.canPromote,
          'noLaterCommands': true,
          'workingUnchanged': true,
          'sourcesUnchanged': true,
          'cancellationUnchanged': true,
          'viewRendered': true,
          'readyForCrash': first,
        },
        sessionBound: true,
        sessionCancel: true,
        sessionCancelActive: sessionCancelActive,
        sessionCancelUnknown: sessionCancelUnknown,
        sessionProof: proof,
      );
    }

    Future<String?> retainedIntent(String dispatch) async {
      if (!uncertain) return null;
      final directory =
          (await receiptRoot
                  .list(followLinks: false)
                  .where((entry) => entry is Directory)
                  .toList())
              .single;
      final intent = File(path.join(directory.path, 'test.intent.json'));
      final result = File(path.join(directory.path, 'test.result.json'));
      if (await FileSystemEntity.isLink(intent.path) ||
          await intent.length() > 4096 ||
          await FileSystemEntity.type(result.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw StateError('Uncertain target result changed');
      }
      final raw = await intent.readAsString();
      final value = jsonDecode(raw);
      final context = CandidateReceiptContext.fromJson(
        jsonDecode(
          await File(path.join(directory.path, 'context.json')).readAsString(),
        ),
      );
      if (value is! Map<String, dynamic> ||
          value.length != 3 ||
          value['version'] != 1 ||
          value['operation'] != 'test' ||
          context.dispatchId != dispatch ||
          !context.matches(
            CandidateReceiptContext.fromJson(value['context']),
          )) {
        throw StateError('Uncertain intent identity mismatch');
      }
      return digest(raw);
    }

    final publicationFault = PromotionCommitFault(records);
    SourceGenerationController? workingController;
    SourceCandidateController makeController(
      GeneratedProject snapshot,
      NativeGenerationHost selectedHost,
    ) {
      if (sessionBound && selectedSession == null) {
        throw StateError('Bound fixture requires its selected session');
      }
      return SourceCandidateController(
        project: project,
        candidate: snapshot,
        evidence: ApprovedSourceProposal(
          projectId: projectId,
          boardTaskId: stop ? 'Tanalyze' : 'fixture',
          approval: approval,
          proposal: SourceEditProposal.parse(
            {
              'summary': 'Fixture review only',
              'changes': [
                {'path': 'lib/main.dart', 'before': 'old', 'after': 'new'},
              ],
            },
            originals: {'lib/main.dart': 'old'},
          ),
        ),
        records: controllerRecords,
        sessionBinding: selectedSession == null
            ? null
            : AgentSessionBinding.select(
                session: selectedSession,
                projectId: projectId,
                boardTaskId: 'Tanalyze',
              ),
        host: selectedHost,
        publish: (value, candidateHost, authorize) async {
          if (!promote || launch != 4) {
            throw StateError('Fixture may not promote');
          }
          if (sessionBound && initialSessionSelection == null) {
            throw StateError(
              'Bound publication requires the initial selection basis',
            );
          }
          final publisher = workingController ??= SourceGenerationController(
            project: project,
            definition: ApplicationStore(records).load(project).definition,
            store: SourceGenerationStore(publicationFault),
            selectedSession: sessionBound && promote
                ? initialSessionSelection
                : selectedSession,
            host: NativeGenerationHost(),
          );
          return publisher.promoteCandidate(
            value,
            candidateHost,
            authorize,
            expectedWorking: SourceGenerationStore(records).load(projectId)!,
          );
        },
      );
    }

    if (sessionBound && launch != 1) {
      selectedSession = AgentSessionStore(
        records,
        project,
      ).load('session-$nonce');
      if (selectedSession == null) {
        throw StateError('Selected session missing on reopen');
      }
      if (promote) {
        final file = File(path.join(canonical, 'initial-session.json'));
        if (await FileSystemEntity.isLink(file.path) ||
            await file.length() > AgentSession.maxEncodedBytes ||
            await file.resolveSymbolicLinks() != file.absolute.path) {
          throw StateError('Invalid initial session selection');
        }
        final initial = AgentSession.fromJson(
          jsonDecode(await file.readAsString()),
        );
        if (initial.storageKey != selectedSession.storageKey ||
            initial.revision != 0 ||
            initial.dispatches.isNotEmpty ||
            initial.cancellationRequested ||
            !initial.approval.matches(selectedSession.approval) ||
            jsonEncode(initial.tasks.toJson()) !=
                jsonEncode(selectedSession.tasks.toJson())) {
          throw StateError('Initial session basis changed');
        }
        AgentSessionAdmission(records, project).requireApproval(initial);
        initialSessionSelection = initial;
      }
      if (sessionCancel) {
        final basisFile = File(path.join(canonical, 'admitted-session.json'));
        if (await FileSystemEntity.isLink(basisFile.path) ||
            await basisFile.length() > AgentSession.maxEncodedBytes) {
          throw StateError('Invalid pre-cancellation binding snapshot');
        }
        final basis = AgentSession.fromJson(
          jsonDecode(await basisFile.readAsString()),
        );
        if (basis.storageKey != selectedSession.storageKey ||
            basis.revision != 1 ||
            basis.cancellationRequested ||
            jsonEncode(basis.requestCancellation().toJson()) !=
                jsonEncode(selectedSession.toJson())) {
          throw StateError('Pre-cancellation binding identity changed');
        }
        selectedSession = basis;
        final controller = makeController(
          checks.load().runs.single.snapshot,
          host,
        );
        await cancellationReport(controller, first: false);
        controller.dispose();
        await host.dispose();
        await records.database.close();
        exit(0);
      }
      if (admissionCrash) {
        await admissionReport(first: false);
        await records.database.close();
        exit(0);
      }
    }
    if (launch == 1) {
      if (records.getString(checks.key) != null || await candidate.exists()) {
        throw StateError('Fixture already reserved.');
      }
      await candidate.create();
      await File(path.join(candidate.path, 'pubspec.yaml')).writeAsString(
        'name: asg_restart_fixture\nenvironment:\n  sdk: ">=3.3.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n',
      );
      final source = File(path.join(candidate.path, 'lib', 'main.dart'));
      await source.parent.create();
      await source.writeAsString(
        "import 'package:flutter/widgets.dart';\nvoid main() => runApp(const SizedBox());\n",
      );
      final test = File(path.join(candidate.path, 'test', 'smoke_test.dart'));
      await test.parent.create();
      await test.writeAsString(
        sessionCancelActive
            ? "import 'dart:io'; import 'package:flutter_test/flutter_test.dart'; void main() { test('fixed active withdrawal', () async { await Directory('build').create(recursive: true); await File('build/running-$nonce').writeAsString('$nonce', flush: true); final release = File('build/release-session-$nonce'); final end = DateTime.now().add(const Duration(seconds: 60)); while (!await release.exists() && DateTime.now().isBefore(end)) { await Future<void>.delayed(const Duration(milliseconds: 20)); } expect(await release.readAsString(), '$nonce'); }); }"
            : running
            ? "import 'dart:io'; import 'package:flutter_test/flutter_test.dart'; void main() { test('fixed running fixture', () async { await Directory('build').create(recursive: true); if (await File('build/allow-retry-$nonce').exists()) { expect(await File('build/allow-retry-$nonce').readAsString(), '$nonce'); return; } await File('build/running-$nonce').writeAsString('$nonce', flush: true); await Future<void>.delayed(const Duration(seconds: 60)); fail('Stop did not reach running test'); }); }"
            : "import 'package:flutter_test/flutter_test.dart';\nvoid main() { test('fixed fixture smoke', () { expect(2 + 2, 4); }); }\n",
      );
      final web = File(path.join(candidate.path, 'web', 'index.html'));
      await web.parent.create();
      await web.writeAsString(
        r'<!DOCTYPE html><html><head><base href="$FLUTTER_BASE_HREF"><meta charset="UTF-8"></head><body><script src="flutter_bootstrap.js" async></script></body></html>',
      );
      await working.parent.create();
      await working.writeAsString('previous working output', flush: true);
      final previousSource = File(
        path.join(working.parent.path, 'lib', 'main.dart'),
      );
      await previousSource.parent.create();
      await previousSource.writeAsString('void main() {}');
      await SourceGenerationStore(records).save(
        projectId,
        GeneratedProject(
          directory: working.parent.path,
          sdk: sdk,
          python: 'python3',
          sources: {'lib/main.dart': digest('void main() {}')},
        ),
      );
      if (stop) {
        await StudioStore(records)
            .save([...StudioStore(records).load(), project]);
        final requirements = RequirementsStore(records);
        await requirements.save(
          projectId,
          requirements.load(projectId),
          RequirementsBoard(
            requirements: [
              ProjectRequirement(
                id: 'R1',
                title: 'Fixture',
                acceptance: 'Fixed verification',
              ),
            ],
            tasks: [
              for (var i = 0; i < operations.length; i++)
                DevelopmentTask(
                  id: 'T${operations[i]}',
                  requirementId: 'R1',
                  title: operations[i],
                  dependencies: i == 0 ? [] : ['T${operations[i - 1]}'],
                  status: TaskStatus.queued,
                ),
            ],
          ),
        );
        final content =
            '```asg-build\n${jsonEncode({
              'version': 3,
              'adapter': 'flutter-starter',
              'tasks': [
                for (var i = 0; i < operations.length; i++) {
                    'id': operations[i],
                    'operation': operations[i],
                    'boardTaskId': 'T${operations[i]}',
                    'dependencies': i == 0 ? <String>[] : [operations[i - 1]],
                  },
              ],
            })}\n```';
        final approvals = PlanApprovalStore(records);
        final messages = [
          ChatMessage(
            role: 'assistant',
            content: content,
            planContext: approvals.contextFor(project),
          ),
        ];
        await ConversationStore(records).save(projectId, messages);
        await approvals.save(project, messages, true);
        approval = approvals.requireCurrentApproval(project);
        if (sessionBound) {
          selectedSession = await AgentSessionStore(records, project).create(
            'session-$nonce',
            RequirementsStore(records)
                .load(projectId)
                .tasks
                .map((task) => task.id)
                .toList(),
          );
          if (promote) {
            initialSessionSelection = selectedSession;
            final file = File(path.join(canonical, 'initial-session.json'));
            await file.create(exclusive: true);
            await file.writeAsString(
              jsonEncode(selectedSession.toJson()),
              flush: true,
            );
          }
        }
        final input = GenerationInput(
          project,
          ApplicationStore(records).load(project).definition,
        );
        for (final entry in {
          'assets/app.json': input.applicationJson,
          'asg_project.json': input.metadataJson,
        }.entries) {
          final file = File(path.join(candidate.path, entry.key));
          await file.parent.create(recursive: true);
          await file.writeAsString(entry.value, flush: true);
        }
      }
      final snapshot = GeneratedProject(
        directory: candidate.path,
        sdk: sdk,
        python: 'python3',
        sources: await NativeGenerationHost.fingerprints(
          candidate.path,
          source: true,
        ),
        confined: true,
        approval: approval,
        tasks: stop
            ? BuildPlan.parse(
                approval.content,
                board: RequirementsStore(records).load(projectId),
              ).tasks
            : null,
        checkpointVersion: 1,
        phase: SourceGenerationPhase.verifying,
        pendingOperation: '',
      );
      stage = 'journal-start';
      final initialRun = stop ? null : await checks.start(snapshot, () {});
      final initialDirectory = initialRun == null
          ? null
          : await receipts.prepare(initialRun, () {});
      late SourceCandidateController runningController;
      late SignalledFixtureHost verifier;
      verifier = SignalledFixtureHost(
        onPrepare: () => receiptPreparations++,
        loadAsset: (key) async {
          final source = await rootBundle.loadString(key);
          if ((!uncertain && !sessionCancelUnknown) ||
              key != 'tools/generation_command.py') {
            return source;
          }
          const anchor = '            receipt.publish(result)';
          if (source.split(anchor).length != 2) {
            throw StateError('Fixture publication anchor changed');
          }
          return source.replaceFirst(
            anchor,
            "            if args.operation == 'test':\n                Path(args.directory, 'build', 'result-fault-$nonce').write_text('$nonce')\n                os._exit(73)\n$anchor",
          );
        },
        receiptFiles: receipts,
        runOperation: (project, currentOperation) async {
          commandEntries++;
          final run = checks.load().runs.single;
          final receiptDirectory =
              initialDirectory ??
              (await receiptRoot
                      .list(followLinks: false)
                      .where((entry) => entry is Directory)
                      .toList())
                  .single
                  .path;
          stage = 'actual-$currentOperation';
          await File(path.join(canonical, '$currentOperation-dispatched'))
              .create(exclusive: true);
          GenerationStep? step;
          if (sessionCancelActive && currentOperation == 'test') {
            final result = verifier
                .runFlutterOperation(
                  project,
                  currentOperation,
                  receiptDirectory: receiptDirectory,
                )
                .then<GenerationStep?>(
                  (value) => value,
                  onError: (Object _, StackTrace _) => null,
                );
            final marker = File(
              path.join(candidate.path, 'build', 'running-$nonce'),
            );
            final deadline = DateTime.now().add(const Duration(seconds: 45));
            while (!await marker.exists() &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            final intent = File(
              path.join(receiptDirectory, 'test.intent.json'),
            );
            final completion = File(
              path.join(receiptDirectory, 'test.result.json'),
            );
            final context = File(path.join(receiptDirectory, 'context.json'));
            if (!await marker.exists() ||
                await FileSystemEntity.isLink(marker.path) ||
                await marker.readAsString() != nonce ||
                !await intent.exists() ||
                await FileSystemEntity.isLink(intent.path) ||
                await completion.exists()) {
              throw StateError('Active test marker/intent boundary missing');
            }
            final intentRaw = await intent.readAsString();
            final contextRaw = await context.readAsString();
            final intentValue = jsonDecode(intentRaw);
            if (intentValue is! Map ||
                intentValue['operation'] != 'test' ||
                jsonEncode(intentValue['context']) !=
                    jsonEncode(jsonDecode(contextRaw))) {
              throw StateError('Active test intent identity mismatch');
            }
            final pending = checks.load().runs.single;
            final admitted = runningController.sessionBinding!.session;
            final executionKey =
                'studio.agentExecution.v1.candidate-$projectId-1';
            final journalBefore = records.getString(checks.key)!;
            final executionBefore = records.getString(executionKey)!;
            if (pending.finished ||
                pending.snapshot.pendingOperation != 'test' ||
                pending.snapshot.steps.length != 2 ||
                admitted.revision != 1 ||
                verifier.stopSignalled ||
                checks.stopRequestFor(pending) != null ||
                AgentExecutionCheckpoint.fromJson(jsonDecode(executionBefore))
                        .phase !=
                    AgentExecutionPhase.executing) {
              throw StateError('Active cancellation startup state mismatch');
            }
            final basis = File(path.join(canonical, 'admitted-session.json'));
            await basis.create(exclusive: true);
            await basis.writeAsString(
              jsonEncode(admitted.toJson()),
              flush: true,
            );
            final cancelled = await AgentSessionStore(
              records,
              runningController.project,
            ).requestCancellation(admitted);
            if (await completion.exists() ||
                !cancelled.cancellationRequested ||
                cancelled.revision != 2 ||
                records.getString(checks.key) != journalBefore ||
                records.getString(executionKey) != executionBefore ||
                verifier.stopSignalled ||
                checks.stopRequestFor(pending) != null) {
              throw StateError(
                'Session withdrawal did not precede actual exit',
              );
            }
            final boundary = File(
              path.join(canonical, 'active-cancellation.json'),
            );
            await boundary.create(exclusive: true);
            await boundary.writeAsString(
              jsonEncode({
                'nonce': nonce,
                'dispatch': pending.dispatchId,
                'beforeRevision': admitted.revision,
                'afterRevision': cancelled.revision,
                'activeBeforeExit': true,
                'intentSha256': digest(intentRaw),
                'contextSha256': digest(contextRaw),
                'markerSha256': digest(await marker.readAsString()),
                'sessionBeforeSha256': digest(jsonEncode(admitted.toJson())),
                'sessionAfterSha256': digest(
                  records.getString(cancelled.storageKey)!,
                ),
                'journalSha256': digest(journalBefore),
                'executionSha256': digest(executionBefore),
              }),
              flush: true,
            );
            final release = File(
              path.join(candidate.path, 'build', 'release-session-$nonce'),
            );
            // The running test must never observe an empty/partially written permit.
            final stagedRelease = File('${release.path}.pending');
            await stagedRelease.create(exclusive: true);
            await stagedRelease.writeAsString(nonce, flush: true);
            if (await FileSystemEntity.type(release.path, followLinks: false) !=
                FileSystemEntityType.notFound) {
              throw StateError('Unexpected active test release');
            }
            await stagedRelease.rename(release.path);
            step = await result.timeout(const Duration(seconds: 20));
            if (sessionCancelUnknown) {
              if (step != null || verifier.stopSignalled) {
                throw StateError(
                  'Publication failure unexpectedly returned an exit',
                );
              }
              await publicationFaultHash();
              // A private helper fault is not a validated Flutter exit result.
              throw StateError(
                'Test outcome remains unknown after publication failure',
              );
            }
            if (step == null ||
                step.exitCode != 0 ||
                step.cancelled ||
                verifier.stopSignalled) {
              throw StateError('Actual late test completion missing');
            }
          } else if (running && currentOperation == operation) {
            // Observe errors immediately while waiting for the live test marker.
            final result = verifier
                .runFlutterOperation(
                  project,
                  currentOperation,
                  receiptDirectory: receiptDirectory,
                )
                .then<GenerationStep?>(
                  (value) => value,
                  onError: (Object _, StackTrace _) => null,
                );
            final marker = File(
              path.join(candidate.path, 'build', 'running-$nonce'),
            );
            final deadline = DateTime.now().add(const Duration(seconds: 45));
            while (!await marker.exists() &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            if (!await marker.exists() ||
                await FileSystemEntity.isLink(marker.path) ||
                await marker.readAsString() != nonce) {
              throw StateError('Running test handshake missing');
            }
            runningController.cancel();
            step = await result.timeout(const Duration(seconds: 12));
            if ((uncertain && step != null) ||
                (step != null && !step.cancelled)) {
              throw StateError('Running test did not cancel');
            }
          } else {
            step = await host.runFlutterOperation(
              project,
              currentOperation,
              receiptDirectory: receiptDirectory,
            );
            if (!step.succeeded) {
              throw StateError('Actual confined operation failed.');
            }
          }
          if (sessionCancel && !sessionCancelActive) {
            if (currentOperation != 'resolve' ||
                step!.exitCode != 0 ||
                step.cancelled) {
              throw StateError(
                'Only the first actual successful receipt may request session cancellation',
              );
            }
            final admitted = runningController.sessionBinding!.session;
            final basis = File(path.join(canonical, 'admitted-session.json'));
            await basis.create(exclusive: true);
            await basis.writeAsString(
              jsonEncode(admitted.toJson()),
              flush: true,
            );
            await AgentSessionStore(
              records,
              runningController.project,
            ).requestCancellation(admitted);
            return step;
          }
          if (sessionCancelActive) return step!;
          if (currentOperation != operation) return step!;
          final pending = checks.load().runs.single;
          final saved = await receipts.read(pending);
          if (pending.snapshot.pendingOperation != operation ||
              pending.snapshot.steps.length != targetIndex ||
              saved.length != targetIndex + (uncertain ? 0 : 1) ||
              saved
                  .take(targetIndex)
                  .any((receipt) => receipt.result.exitCode != 0) ||
              (!uncertain && running
                  ? !saved.last.result.cancelled ||
                        saved.last.result.exitCode == 0
                  : saved.last.result.exitCode != 0)) {
            throw StateError('Pending operation/receipt prefix mismatch.');
          }
          if (stop) {
            runningController.cancel();
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while ((precommit
                    ? !barrier.reached
                    : runningController.stopRequestSaving) &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            if (!verifier.stopSignalled ||
                runningController.stopRequestSaveError != null ||
                (precommit
                    ? !barrier.reached ||
                          !runningController.stopRequestSaving ||
                          checks.stopRequestFor(pending) != null
                    : runningController.stopRequestSaving ||
                          checks.stopRequestFor(pending) == null)) {
              throw StateError('Durable Stop intent missing.');
            }
          }
          final intentHash = await retainedIntent(run.dispatchId!);
          if (uncertain) {
            final fault = File(
              path.join(candidate.path, 'build', 'result-fault-$nonce'),
            );
            if (!await fault.exists() || await fault.readAsString() != nonce) {
              throw StateError('Publication fault not observed');
            }
          }
          final stopRaw = records.getString(
            '${CandidateVerificationStore.stopPrefix}${run.dispatchId}',
          );
          final state = {
            'stop': stopRaw == null ? null : digest(stopRaw),
            'intent': intentHash,
            'journal': digest(records.getString(checks.key)!),
            'candidate': digest(records.getString(checks.candidateKey)!),
            'working': digest(records.getString(workingKey)!),
            'output': digest(await working.readAsString()),
            'dispatch': run.dispatchId,
            if (sessionBound) 'sessionProof': await sessionProof(),
            if (sessionBound && retry)
              'sessionRetryProof': await sessionRetryProof(),
          };
          final before = File(path.join(canonical, 'before.json'));
          await before.create(exclusive: true);
          await before.writeAsString(jsonEncode(state), flush: true);
          await report(
            canonical,
            1,
            {
              'nonce': nonce,
              'dispatch': run.dispatchId,
              'operation': operation,
              'completedOperations': pending.snapshot.steps
                  .map((step) => step.operation)
                  .toList(),
              'readyForCrash': true,
              'stopRequested': stop,
              'precommit': precommit,
              'running': running,
              'uncertain': uncertain,
              'acknowledge': acknowledge,
              'retry': retry,
              'promote': promote,
              'promotionCrash': promotionCrash,
              'publicationFault': uncertain,
              'runningMarker': running,
              'stopSaveBlocked': barrier.reached,
              'stopSignalled': verifier.stopSignalled,
            },
            sessionBound: sessionBound,
            sessionProof: await sessionProof(),
            sessionRetryProof: await sessionRetryProof(),
            beforeActionSha256: sessionBound && retry
                ? retryDigest((await sessionRetryProof())!)
                : null,
          );
          runApp(
            MaterialApp(
              home: Scaffold(
                body: Text('Disposable $operation: ready for owned crash'),
              ),
            ),
          );
          await Future<void>.delayed(const Duration(seconds: 45));
          exit(3);
        },
      );
      if (admissionCrash) {
        admissionBarrier.onAdmission = () async {
          await admissionReport(first: true);
          await Completer<void>().future;
        };
      }
      if (stop) {
        runningController = makeController(snapshot, verifier);
        stage = 'controller-authority';
        ApprovedSourceProposer(records)
            .requireCurrent(project, runningController.evidence);
        stage = 'controller-inputs';
        if (!BuildPlan.parse(
          approval.content,
          board: RequirementsStore(records).load(projectId),
        ).matchesTasks(snapshot.tasks)) {
          throw StateError('Fixture task mismatch');
        }
        if (GenerationInput(
              project,
              ApplicationStore(records).load(project).definition,
            ).compare(snapshot) !=
            GeneratedSnapshotStatus.current) {
          throw StateError('Fixture input mismatch');
        }
        stage = 'controller-verification';
        if (sessionCancel) initialCancellationOutput = await outputState();
        await runningController.verify(approved: true);
        if (sessionCancel) {
          await cancellationReport(runningController, first: true);
          await Completer<void>().future;
        }
        stage =
            'controller-returned-runs-${checks.load().runs.length}-pending-${runningController.result.pendingOperation}-failed-${runningController.result.failedOperation}';
      } else {
        await verifier.verify(
          snapshot,
          (current) => checks.checkpoint(current, () {}),
        );
      }
      throw StateError('Target operation did not reach crash boundary.');
    }
    stage = 'recovery-read';
    final beforeFile = File(
      path.join(
        canonical,
        launch == 5
            ? 'after-promote.json'
            : launch == 4
            ? 'after-retry.json'
            : acknowledged
            ? 'after-ack.json'
            : 'before.json',
      ),
    );
    final before =
        jsonDecode(await beforeFile.readAsString()) as Map<String, dynamic>;
    final run = checks.load().runs.first;
    final snapshot = run.snapshot;
    if (stop) approval = snapshot.approval!;
    final controller = makeController(
      launch >= 4 ? checks.load().runs.last.snapshot : snapshot,
      host,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (controller.receiptsFor(run).isEmpty &&
        controller.receiptHistoryError == null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final retained = controller.receiptsFor(run);
    bool sameStop() {
      final raw = records.getString(
        '${CandidateVerificationStore.stopPrefix}${run.dispatchId}',
      );
      return stop && !precommit
          ? raw != null &&
                digest(raw) == before['stop'] &&
                controller.stopRequestFor(run) != null
          : raw == null &&
                before['stop'] == null &&
                controller.stopRequestFor(run) == null;
    }

    bool sameAction() {
      if (!acknowledged) return true;
      final actionKey =
          '${CandidateVerificationStore.recoveryPrefix}${run.dispatchId}';
      final executionKey =
          'studio.agentExecution.v1.${run.dispatchId!.split(':').first}';
      final action = controller.acknowledgementFor(run);
      final saved = controller.savedExecutionFor(run);
      return action != null &&
          action.matches(projectId, run) &&
          digest(records.getString(actionKey)!) == before['action'] &&
          digest(records.getString(executionKey)!) == before['execution'] &&
          saved?.phase.name == 'awaitingApproval' &&
          checks.load().runs.length == (launch >= 4 ? 2 : 1);
    }

    Future<bool> sameRetry() async {
      if (launch < 4) return true;
      final runs = checks.load().runs;
      if (runs.length != 2) return false;
      final latest = runs.last;
      final executionKey = 'studio.agentExecution.v1.candidate-$projectId-2';
      final completed = await receipts.read(latest);
      return latest.dispatchId == 'candidate-$projectId-2:3' &&
          latest.finished &&
          latest.snapshot.phase == SourceGenerationPhase.ready &&
          latest.snapshot.steps.length == 4 &&
          latest.snapshot.steps.every((step) => step.succeeded) &&
          jsonEncode(
                latest.snapshot.steps.map((step) => step.operation).toList(),
              ) ==
              jsonEncode(operations) &&
          digest(jsonEncode(latest.toJson())) == before['retryRun'] &&
          digest(records.getString(executionKey)!) ==
              before['retryExecution'] &&
          controller.savedExecutionFor(latest)?.phase.name ==
              (launch == 5 ? 'completed' : 'verifying') &&
          completed.length == 4 &&
          completed.every(
            (receipt) =>
                receipt.result.exitCode == 0 && !receipt.result.cancelled,
          ) &&
          jsonEncode(
                completed.map((receipt) => receipt.operation.name).toList(),
              ) ==
              jsonEncode(operations) &&
          NativeGenerationHost.sameFiles(
            await NativeGenerationHost.fingerprints(
              path.join(snapshot.directory, 'build', 'web'),
              source: false,
            ),
            latest.snapshot.outputs,
          );
    }

    final currentSources = await NativeGenerationHost.fingerprints(
      snapshot.directory,
      source: true,
    );
    if (!await sameRetry() ||
        !sameAction() ||
        await retainedIntent(run.dispatchId!) != before['intent'] ||
        !sameStop() ||
        controller.stopRequestHistoryError != null ||
        controller.historyError != null ||
        controller.receiptHistoryError != null ||
        run.finished != acknowledged ||
        run.snapshot.pendingOperation != operation ||
        run.dispatchId != before['dispatch'] ||
        retained.length != targetIndex + (uncertain ? 0 : 1) ||
        retained
            .take(targetIndex)
            .any((receipt) => receipt.result.exitCode != 0) ||
        (!uncertain && running
            ? !retained.last.result.cancelled ||
                  retained.last.result.exitCode == 0
            : retained.last.result.exitCode != 0) ||
        jsonEncode(
              retained.map((receipt) => receipt.operation.name).toList(),
            ) !=
            jsonEncode(
              operations.take(targetIndex + (uncertain ? 0 : 1)).toList(),
            ) ||
        jsonEncode(run.snapshot.steps.map((step) => step.operation).toList()) !=
            jsonEncode(operations.take(targetIndex).toList()) ||
        run.snapshot.steps.any((step) => !step.succeeded) ||
        (launch < 4 && controller.canPromote) ||
        !NativeGenerationHost.sameFiles(currentSources, snapshot.sources) ||
        (acknowledged
            ? !sameAction()
            : controller.savedExecutionFor(run)?.dispatchId !=
                  run.dispatchId) ||
        digest(records.getString(checks.key)!) != before['journal'] ||
        digest(records.getString(checks.candidateKey)!) !=
            before['candidate'] ||
        digest(records.getString(workingKey)!) != before['working'] ||
        digest(await working.readAsString()) != before['output']) {
      throw StateError('Recovered candidate observations changed.');
    }
    stage = 'recovery-view';
    final viewKey = GlobalKey();
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SourceCandidateView(
              key: viewKey,
              controller: controller,
              actionsEnabled: acknowledged,
            ),
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    final text = <String>[];
    bool? consent, verifyEnabled;
    ValueChanged<bool?>? selectConsent;
    VoidCallback? startVerification;
    final expansions = <ExpansibleController>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is CheckboxListTile &&
          widget.title is Text &&
          (widget.title as Text).data ==
              'I approve confined candidate verification') {
        consent = widget.value;
        selectConsent = widget.onChanged;
      }
      if (widget is FilledButton &&
          widget.child is Text &&
          (widget.child as Text).data == 'Verify candidate in sandbox') {
        verifyEnabled = widget.onPressed != null;
        startVerification = widget.onPressed;
      }
      if (widget is Expansible) expansions.add(widget.controller);
      if (widget is Text && widget.data != null) text.add(widget.data!);
      if (widget is SelectableText && widget.data != null) {
        text.add(widget.data!);
      }
      element.visitChildElements(visit);
    }

    for (var depth = 0; depth < 3; depth++) {
      expansions.clear();
      viewKey.currentContext!.visitChildElements(visit);
      for (final expansion in expansions) {
        expansion.expand();
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await WidgetsBinding.instance.endOfFrame;
    }
    text.clear();
    viewKey.currentContext!.visitChildElements(visit);
    if ((text.any((value) => value.contains('Saved Stop request.')) !=
            (stop && !precommit)) ||
        !text.any(
          (value) => value.contains(
            'Candidate checks: ${launch >= 4
                ? 'ready'
                : acknowledged
                ? 'failed'
                : 'verifying'}',
          ),
        ) ||
        (uncertain
            ? text.any((value) => value.contains('Retained $operation result:'))
            : !text.any(
                (value) => value.contains(
                  'Retained $operation result: exit ${retained.last.result.exitCode}',
                ),
              ))) {
      throw StateError('Production candidate view did not render.');
    }
    if (acknowledged &&
        (!text.any(
              (value) => value.startsWith(
                'Operator recovery acknowledgement saved at',
              ),
            ) ||
            consent != false ||
            verifyEnabled != false)) {
      throw StateError('Acknowledgement view or fresh consent mismatch');
    }
    // Rendering must remain read-only too, including any future view callbacks.
    if (!await sameRetry() ||
        !sameAction() ||
        await retainedIntent(run.dispatchId!) != before['intent'] ||
        !sameStop() ||
        digest(records.getString(checks.key)!) != before['journal'] ||
        digest(records.getString(checks.candidateKey)!) !=
            before['candidate'] ||
        digest(records.getString(workingKey)!) != before['working'] ||
        digest(await working.readAsString()) != before['output'] ||
        !NativeGenerationHost.sameFiles(
          await NativeGenerationHost.fingerprints(
            snapshot.directory,
            source: true,
          ),
          snapshot.sources,
        )) {
      throw StateError('Rendering changed retained fixture state.');
    }
    final retryBeforeAction = await sessionRetryProof();
    if (retryBeforeAction != null &&
        retryDigest(retryBeforeAction) !=
            retryDigest(
              Map<String, Object?>.from(before['sessionRetryProof'] as Map),
            )) {
      throw StateError('Read-only retry reopen changed stage evidence');
    }
    final actionUnchangedBefore = acknowledged && sameAction();
    final freshConsentBefore =
        acknowledged && consent == false && verifyEnabled == false;
    final noNewDispatchBefore =
        checks.load().runs.length == (launch >= 4 ? 2 : 1);
    final observedExecutionPhase = controller
        .savedExecutionFor(run)!
        .phase
        .name;
    var acknowledgedAfterRead = false;
    if (acknowledge && launch == 2) {
      stage = 'explicit-fixture-acknowledgement';
      await controller.acknowledgeStopped(run);
      final stopped = checks.load().runs.single;
      final action = controller.acknowledgementFor(stopped);
      final executionKey =
          'studio.agentExecution.v1.${run.dispatchId!.split(':').first}';
      final actionKey =
          '${CandidateVerificationStore.recoveryPrefix}${run.dispatchId}';
      if (controller.error != null ||
          !stopped.finished ||
          action == null ||
          controller.savedExecutionFor(stopped)?.phase.name !=
              'awaitingApproval' ||
          !NativeGenerationHost.sameFiles(
            await NativeGenerationHost.fingerprints(
              snapshot.directory,
              source: true,
            ),
            snapshot.sources,
          ) ||
          digest(records.getString(workingKey)!) != before['working'] ||
          digest(await working.readAsString()) != before['output']) {
        throw StateError('Explicit fixture acknowledgement failed');
      }
      final after = File(path.join(canonical, 'after-ack.json'));
      await after.create(exclusive: true);
      await after.writeAsString(
        jsonEncode({
          ...before,
          'journal': digest(records.getString(checks.key)!),
          'action': digest(records.getString(actionKey)!),
          'execution': digest(records.getString(executionKey)!),
          if (sessionBound && retry)
            'sessionRetryProof': await sessionRetryProof(),
        }),
        flush: true,
      );
      acknowledgedAfterRead = true;
    }
    var retriedAfterRead = false;
    String? newDispatch = launch >= 4
        ? checks.load().runs.last.dispatchId
        : null;
    if (retry && launch == 3) {
      stage = 'explicit-fixture-verification-consent';
      if (!freshConsentBefore ||
          !noNewDispatchBefore ||
          selectConsent == null) {
        throw StateError('Fresh consent was not required');
      }
      selectConsent!(true);
      await WidgetsBinding.instance.endOfFrame;
      viewKey.currentContext!.visitChildElements(visit);
      if (consent != true ||
          verifyEnabled != true ||
          startVerification == null) {
        throw StateError('Explicit consent did not enable verification');
      }
      final permit = File(
        path.join(candidate.path, 'build', 'allow-retry-$nonce'),
      );
      await permit.create(exclusive: true);
      await permit.writeAsString(nonce, flush: true);
      startVerification!();
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      while (controller.busy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final runs = checks.load().runs;
      if (controller.busy ||
          controller.error != null ||
          runs.length != 2 ||
          runs.last.dispatchId != 'candidate-$projectId-2:3' ||
          !runs.last.finished ||
          runs.last.snapshot.phase != SourceGenerationPhase.ready ||
          runs.last.snapshot.steps.length != 4 ||
          runs.last.snapshot.steps.any((step) => !step.succeeded) ||
          digest(
                records.getString(
                  '${CandidateVerificationStore.recoveryPrefix}${run.dispatchId}',
                )!,
              ) !=
              before['action'] ||
          digest(
                records.getString(
                  'studio.agentExecution.v1.${run.dispatchId!.split(':').first}',
                )!,
              ) !=
              before['execution'] ||
          digest(records.getString(workingKey)!) != before['working'] ||
          digest(await working.readAsString()) != before['output'] ||
          !NativeGenerationHost.sameFiles(
            await NativeGenerationHost.fingerprints(
              snapshot.directory,
              source: true,
            ),
            snapshot.sources,
          )) {
        throw StateError('Explicit fresh verification failed');
      }
      final latest = runs.last;
      final after = File(path.join(canonical, 'after-retry.json'));
      await after.create(exclusive: true);
      await after.writeAsString(
        jsonEncode({
          ...before,
          'journal': digest(records.getString(checks.key)!),
          'candidate': digest(records.getString(checks.candidateKey)!),
          'retryRun': digest(jsonEncode(latest.toJson())),
          'retryExecution': digest(
            records.getString(
              'studio.agentExecution.v1.candidate-$projectId-2',
            )!,
          ),
          if (sessionBound && retry)
            'sessionRetryProof': await sessionRetryProof(),
        }),
        flush: true,
      );
      newDispatch = latest.dispatchId;
      retriedAfterRead = true;
    }
    var promotedAfterRead = false,
        refusedPublicationPreserved = false,
        previewResponded = false;
    if (promote && launch == 4) {
      stage = 'explicit-native-promotion';
      final oldWorking = records.getString(workingKey)!;
      final previousKey = 'studio.generationPrevious.v1.$projectId';
      final previous = records.getString(previousKey);
      final executionKey = 'studio.agentExecution.v1.candidate-$projectId-2';
      final executionBefore = records.getString(executionKey)!;
      final refusalProof = await sessionRetryProof();
      Future<void> savePromotionBaseline() async {
        final after = File(path.join(canonical, 'after-promote.json'));
        await after.create(exclusive: true);
        await after.writeAsString(
          jsonEncode({
            ...before,
            'working': digest(records.getString(workingKey)!),
            'previous': digest(records.getString(previousKey)!),
            'retryExecution': digest(records.getString(executionKey)!),
            if (sessionBound && retry)
              'sessionRetryProof': await sessionRetryProof(),
          }),
          flush: true,
        );
      }

      if (!controller.canPromote ||
          await controller.promote(approved: true) ||
          !publicationFault.reached ||
          controller.promoted ||
          records.getString(workingKey) != oldWorking ||
          records.getString(previousKey) != previous ||
          records.getString(executionKey) != executionBefore ||
          !await sameRetry() ||
          !sameAction() ||
          !sameStop()) {
        throw StateError('Refused publication changed durable state');
      }
      if (refusalProof != null &&
          retryDigest(refusalProof) !=
              retryDigest((await sessionRetryProof())!)) {
        throw StateError(
          'Refused publication changed bound session or stage records',
        );
      }
      refusedPublicationPreserved = true;
      publicationFault.refuse = false;
      if (promotionCrash) {
        publicationFault.afterPublicationCommit = () async {
          stage = 'after-promotion-commit-before-return';
          if (controller.promoted ||
              !controller.busy ||
              !controller.promoting ||
              controller.preview != null ||
              controller
                      .savedExecutionFor(checks.load().runs.last)
                      ?.phase
                      .name !=
                  'completed' ||
              records.getString(previousKey) != oldWorking ||
              jsonEncode(
                    SourceGenerationStore(records).load(projectId)!.toJson(),
                  ) !=
                  jsonEncode(checks.load().runs.last.snapshot.toJson()) ||
              !sameAction() ||
              !sameStop() ||
              digest(records.getString(checks.key)!) != before['journal'] ||
              digest(records.getString(checks.candidateKey)!) !=
                  before['candidate'] ||
              digest(await working.readAsString()) != before['output'] ||
              !NativeGenerationHost.sameFiles(
                await NativeGenerationHost.fingerprints(
                  snapshot.directory,
                  source: true,
                ),
                snapshot.sources,
              )) {
            throw StateError('Committed publication boundary mismatch');
          }
          final preview = host.preparedPreview;
          if (preview == null || preview.host != '127.0.0.1') {
            throw StateError('Prepared preview missing');
          }
          final client = HttpClient();
          try {
            final response =
                await (await client
                        .getUrl(preview)
                        .timeout(const Duration(seconds: 5)))
                    .close()
                    .timeout(const Duration(seconds: 5));
            final body = await utf8.decoder
                .bind(response)
                .join()
                .timeout(const Duration(seconds: 5));
            if (response.statusCode != 200 || !body.contains('<html')) {
              throw StateError('Committed preview unavailable');
            }
            previewResponded = true;
          } finally {
            client.close(force: true);
          }
          await savePromotionBaseline();
          await report(
            canonical,
            launch,
            {
              'commitGapReady': true,
              'previewResponded': previewResponded,
              'controllerSuccessDelivered': false,
              'nonce': nonce,
              'dispatch': run.dispatchId,
              'interrupted': !acknowledged,
              'acknowledge': acknowledge,
              'retry': retry,
              'promote': promote,
              'promotionCrash': promotionCrash,
              'promotedAfterRead': promotedAfterRead,
              'refusedPublicationPreserved': refusedPublicationPreserved,
              'promotionSurvived': false,
              'retriedAfterRead': retriedAfterRead,
              'newDispatch': newDispatch,
              'retryChecksPassed': true,
              'oldEvidencePreserved':
                  retriedAfterRead || (launch >= 4 && sameAction()),
              'acknowledgedAfterRead': acknowledgedAfterRead,
              'afterAcknowledgementPhase': acknowledgedAfterRead
                  ? 'awaitingApproval'
                  : null,
              'actionUnchanged': actionUnchangedBefore,
              'freshConsentRequired': freshConsentBefore,
              'noNewDispatch': noNewDispatchBefore,
              'stopRequested': stop,
              'precommit': precommit,
              'running': running,
              'uncertain': uncertain,
              'intentUnchanged':
                  await retainedIntent(run.dispatchId!) == before['intent'],
              'runningCancelled':
                  running && !uncertain && retained.last.result.cancelled,
              'savedStopPresent': controller.stopRequestFor(run) != null,
              'stopUnchanged': sameStop(),
              'operation': operation,
              'completedOperations': run.snapshot.steps
                  .map((step) => step.operation)
                  .toList(),
              'receiptOperations': retained
                  .map((receipt) => receipt.operation.name)
                  .toList(),
              'retainedExit': uncertain ? null : retained.last.result.exitCode,
              'cleanup': 'unknown',
              'journalUnchanged': true,
              'sourcesUnchanged': true,
              'workingUnchanged': true,
              'viewRendered': true,
              'executionPhase': observedExecutionPhase,
            },
            sessionBound: sessionBound,
            sessionRetryProof: await sessionRetryProof(),
            beforeActionSha256: retryBeforeAction == null
                ? null
                : retryDigest(retryBeforeAction),
          );
          await Completer<void>()
              .future; // Host kills only this owned app handle.
          throw StateError('Commit barrier must not return');
        };
      }

      if (!await controller.promote(approved: true) ||
          !controller.promoted ||
          controller.preview?.host != '127.0.0.1' ||
          controller.savedExecutionFor(checks.load().runs.last)?.phase.name !=
              'completed' ||
          records.getString(previousKey) != oldWorking ||
          jsonEncode(
                SourceGenerationStore(records).load(projectId)!.toJson(),
              ) !=
              jsonEncode(checks.load().runs.last.snapshot.toJson()) ||
          !sameAction() ||
          !sameStop() ||
          digest(records.getString(checks.key)!) != before['journal'] ||
          digest(records.getString(checks.candidateKey)!) !=
              before['candidate'] ||
          digest(await working.readAsString()) != before['output']) {
        throw StateError(
          'Native promotion did not preserve execution identity',
        );
      }
      final client = HttpClient();
      try {
        final response =
            await (await client
                    .getUrl(controller.preview!)
                    .timeout(const Duration(seconds: 5)))
                .close()
                .timeout(const Duration(seconds: 5));
        final body = await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 5));
        if (response.statusCode != 200 || !body.contains('<html')) {
          throw StateError('Promoted native preview unavailable');
        }
        previewResponded = true;
      } finally {
        client.close(force: true);
      }
      await savePromotionBaseline();
      promotedAfterRead = true;
    }
    final promotionSurvived =
        launch == 5 &&
        digest(records.getString('studio.generationPrevious.v1.$projectId')!) ==
            before['previous'] &&
        jsonEncode(SourceGenerationStore(records).load(projectId)!.toJson()) ==
            jsonEncode(checks.load().runs.last.snapshot.toJson());
    if (launch == 5 && !promotionSurvived) {
      throw StateError('Published restart changed');
    }
    await report(
      canonical,
      launch,
      {
        'nonce': nonce,
        'dispatch': run.dispatchId,
        'interrupted': !acknowledged,
        'acknowledge': acknowledge,
        'retry': retry,
        'promote': promote,
        'promotionCrash': promotionCrash,
        'promotedAfterRead': promotedAfterRead,
        'refusedPublicationPreserved': refusedPublicationPreserved,
        'promotionSurvived': promotionSurvived,
        'previewResponded': previewResponded,
        'retriedAfterRead': retriedAfterRead,
        'newDispatch': newDispatch,
        'retryChecksPassed':
            retriedAfterRead ||
            (launch >= 4 && (promotedAfterRead || await sameRetry())),
        'oldEvidencePreserved':
            retriedAfterRead || (launch >= 4 && sameAction()),
        'acknowledgedAfterRead': acknowledgedAfterRead,
        'afterAcknowledgementPhase': acknowledgedAfterRead
            ? 'awaitingApproval'
            : null,
        'actionUnchanged': actionUnchangedBefore,
        'freshConsentRequired': freshConsentBefore,
        'noNewDispatch': noNewDispatchBefore,
        'stopRequested': stop,
        'precommit': precommit,
        'running': running,
        'uncertain': uncertain,
        'intentUnchanged':
            await retainedIntent(run.dispatchId!) == before['intent'],
        'runningCancelled':
            running && !uncertain && retained.last.result.cancelled,
        'savedStopPresent': controller.stopRequestFor(run) != null,
        'stopUnchanged': sameStop(),
        'operation': operation,
        'completedOperations': run.snapshot.steps
            .map((step) => step.operation)
            .toList(),
        'receiptOperations': retained
            .map((receipt) => receipt.operation.name)
            .toList(),
        'retainedExit': uncertain ? null : retained.last.result.exitCode,
        'cleanup': 'unknown',
        'journalUnchanged': true,
        'sourcesUnchanged': true,
        'workingUnchanged': true,
        'viewRendered': true,
        'executionPhase': observedExecutionPhase,
      },
      sessionBound: sessionBound,
      sessionProof: await sessionProof(),
      sessionRetryProof: await sessionRetryProof(),
      beforeActionSha256: retryBeforeAction == null
          ? null
          : retryDigest(retryBeforeAction),
    );
    controller.dispose();
    workingController?.dispose();
    await host.dispose();
    await records.database.close();
    exit(0);
  } catch (error) {
    stderr.writeln(
      'Native candidate crash fixture failed at $stage (${error.runtimeType}).',
    );
    exit(2);
  }
}

Future<void> report(
  String root,
  int launch,
  Map<String, Object?> observation, {
  bool sessionBound = false,
  bool admissionCrash = false,
  bool sessionCancel = false,
  bool sessionCancelActive = false,
  bool sessionCancelUnknown = false,
  Map<String, Object?>? sessionProof,
  Map<String, Object?>? sessionRetryProof,
  String? beforeActionSha256,
}) async {
  final file = File(path.join(root, 'launch-$launch.json'));
  await file.create(exclusive: true);
  await file.writeAsString(
    jsonEncode({
      'version': 16,
      'launch': launch,
      ...observation,
      'sessionBound': sessionBound,
      'admissionCrash': admissionCrash,
      'sessionCancel': sessionCancel,
      'sessionCancelActive': sessionCancelActive,
      'sessionCancelUnknown': sessionCancelUnknown,
      'sessionProof': sessionProof,
      'sessionRetryProof': sessionRetryProof,
      'beforeActionSha256': beforeActionSha256,
    }),
    flush: true,
  );
}

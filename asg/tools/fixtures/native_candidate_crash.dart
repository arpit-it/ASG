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

final class SignalledFixtureHost extends NativeGenerationHost {
  SignalledFixtureHost({
    required super.receiptFiles,
    required super.runOperation,
    super.loadAsset,
  });
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
        input.length != 12 ||
        input['nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(input['nonce'] as String) ||
        ![1, 2, 3, 4, 5].contains(input['launch']) ||
        input['sdk'] is! String ||
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
    final controllerRecords = precommit && launch == 1 ? barrier : records;
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
    final host = NativeGenerationHost(receiptFiles: receipts);
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
        host: selectedHost,
        publish: (value, candidateHost, authorize) async {
          if (!promote || launch != 4) {
            throw StateError('Fixture may not promote');
          }
          final publisher = workingController ??= SourceGenerationController(
            project: project,
            definition: ApplicationStore(records).load(project).definition,
            store: SourceGenerationStore(publicationFault),
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
        running
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
        loadAsset: (key) async {
          final source = await rootBundle.loadString(key);
          if (!uncertain || key != 'tools/generation_command.py') return source;
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
          if (running && currentOperation == operation) {
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
          };
          final before = File(path.join(canonical, 'before.json'));
          await before.create(exclusive: true);
          await before.writeAsString(jsonEncode(state), flush: true);
          await report(canonical, 1, {
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
          });
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
        await runningController.verify(approved: true);
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
        }),
        flush: true,
      );
      newDispatch = latest.dispatchId;
      retriedAfterRead = true;
    }
    var promotedAfterRead = false, refusedPublicationPreserved = false;
    if (promote && launch == 4) {
      stage = 'explicit-native-promotion';
      final oldWorking = records.getString(workingKey)!;
      final previousKey = 'studio.generationPrevious.v1.$projectId';
      final previous = records.getString(previousKey);
      final executionKey = 'studio.agentExecution.v1.candidate-$projectId-2';
      final executionBefore = records.getString(executionKey)!;
      Future<void> savePromotionBaseline() async {
        final after = File(path.join(canonical, 'after-promote.json'));
        await after.create(exclusive: true);
        await after.writeAsString(
          jsonEncode({
            ...before,
            'working': digest(records.getString(workingKey)!),
            'previous': digest(records.getString(previousKey)!),
            'retryExecution': digest(records.getString(executionKey)!),
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
          await savePromotionBaseline();
          await report(canonical, launch, {
            'commitGapReady': true,
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
          });
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
    await report(canonical, launch, {
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
      'retriedAfterRead': retriedAfterRead,
      'newDispatch': newDispatch,
      'retryChecksPassed':
          retriedAfterRead ||
          (launch >= 4 && (promotedAfterRead || await sameRetry())),
      'oldEvidencePreserved': retriedAfterRead || (launch >= 4 && sameAction()),
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
    });
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
  Map<String, Object?> observation,
) async {
  final file = File(path.join(root, 'launch-$launch.json'));
  await file.create(exclusive: true);
  await file.writeAsString(
    jsonEncode({'version': 10, 'launch': launch, ...observation}),
    flush: true,
  );
}

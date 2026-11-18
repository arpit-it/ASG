// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

// Disposable native fixture; never referenced by production main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:asg/controllers/source_candidate_controller.dart';
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

final class SignalledFixtureHost extends NativeGenerationHost {
  SignalledFixtureHost({
    required super.receiptFiles,
    required super.runOperation,
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
        input.length != 6 ||
        input['nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(input['nonce'] as String) ||
        ![1, 2].contains(input['launch']) ||
        input['sdk'] is! String ||
        input['stop'] is! bool ||
        input['precommit'] is! bool ||
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
        publish: (_, _, _) => throw StateError('Fixture may not promote'),
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
        "import 'package:flutter_test/flutter_test.dart';\nvoid main() { test('fixed fixture smoke', () { expect(2 + 2, 4); }); }\n",
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
          final step = await host.runFlutterOperation(
            project,
            currentOperation,
            receiptDirectory: receiptDirectory,
          );
          if (!step.succeeded) {
            throw StateError('Actual confined operation failed.');
          }
          if (currentOperation != operation) return step;
          final pending = checks.load().runs.single;
          final saved = await receipts.read(pending);
          if (pending.snapshot.pendingOperation != operation ||
              pending.snapshot.steps.length != targetIndex ||
              saved.length != targetIndex + 1 ||
              saved.any((receipt) => receipt.result.exitCode != 0)) {
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
          final stopRaw = records.getString(
            '${CandidateVerificationStore.stopPrefix}${run.dispatchId}',
          );
          final state = {
            'stop': stopRaw == null ? null : digest(stopRaw),
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
    final beforeFile = File(path.join(canonical, 'before.json'));
    final before =
        jsonDecode(await beforeFile.readAsString()) as Map<String, dynamic>;
    final run = checks.load().runs.single;
    final snapshot = run.snapshot;
    if (stop) approval = snapshot.approval!;
    final controller = makeController(snapshot, host);
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

    final currentSources = await NativeGenerationHost.fingerprints(
      snapshot.directory,
      source: true,
    );
    if (!sameStop() ||
        controller.stopRequestHistoryError != null ||
        controller.historyError != null ||
        controller.receiptHistoryError != null ||
        run.finished ||
        run.snapshot.pendingOperation != operation ||
        run.dispatchId != before['dispatch'] ||
        retained.length != targetIndex + 1 ||
        retained.any((receipt) => receipt.result.exitCode != 0) ||
        jsonEncode(
              retained.map((receipt) => receipt.operation.name).toList(),
            ) !=
            jsonEncode(operations.take(targetIndex + 1).toList()) ||
        jsonEncode(run.snapshot.steps.map((step) => step.operation).toList()) !=
            jsonEncode(operations.take(targetIndex).toList()) ||
        run.snapshot.steps.any((step) => !step.succeeded) ||
        controller.canPromote ||
        !NativeGenerationHost.sameFiles(currentSources, snapshot.sources) ||
        controller.savedExecutionFor(run)?.dispatchId != run.dispatchId ||
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
              actionsEnabled: false,
            ),
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    final text = <String>[];
    final expansions = <ExpansibleController>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Expansible) expansions.add(widget.controller);
      if (widget is Text && widget.data != null) text.add(widget.data!);
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
        !text.any((value) => value.contains('Candidate checks: verifying')) ||
        !text.any(
          (value) => value.contains('Retained $operation result: exit 0'),
        )) {
      throw StateError('Production candidate view did not render.');
    }
    // Rendering must remain read-only too, including any future view callbacks.
    if (!sameStop() ||
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
    await report(canonical, 2, {
      'nonce': nonce,
      'dispatch': run.dispatchId,
      'interrupted': true,
      'stopRequested': stop,
      'precommit': precommit,
      'savedStopPresent': controller.stopRequestFor(run) != null,
      'stopUnchanged': sameStop(),
      'operation': operation,
      'completedOperations': run.snapshot.steps
          .map((step) => step.operation)
          .toList(),
      'receiptOperations': retained
          .map((receipt) => receipt.operation.name)
          .toList(),
      'retainedExit': retained.last.result.exitCode,
      'cleanup': 'unknown',
      'journalUnchanged': true,
      'sourcesUnchanged': true,
      'workingUnchanged': true,
      'viewRendered': true,
      'executionPhase': controller.savedExecutionFor(run)!.phase.name,
    });
    controller.dispose();
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
    jsonEncode({'version': 4, 'launch': launch, ...observation}),
    flush: true,
  );
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

// Disposable native fixture; never referenced by production main.dart.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/plan_approval.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/candidate_receipt_native.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/source_candidate_view.dart';

const bundle = 'com.arsinha.asg.restartfixture';
const operations = ['resolve', 'analyze', 'test', 'build'];

String digest(String text) => sha256.convert(utf8.encode(text)).toString();

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
        input.length != 4 ||
        input['nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(input['nonce'] as String) ||
        ![1, 2].contains(input['launch']) ||
        input['sdk'] is! String ||
        !operations.contains(input['operation'])) {
      throw StateError('Invalid challenge schema.');
    }
    final nonce = input['nonce'] as String;
    final launch = input['launch'] as int;
    final operation = input['operation'] as String;
    final targetIndex = operations.indexOf(operation);
    final sdk = await Directory(input['sdk'] as String).resolveSymbolicLinks();
    final support = await getApplicationSupportDirectory();
    if (path.basename(support.path) != bundle ||
        await support.resolveSymbolicLinks() !=
            path.normalize(support.absolute.path)) {
      throw StateError('Fixture support required.');
    }
    stage = 'database';
    final records = await StudioDatabase.open();
    final projectId = 'restart-$nonce';
    final checks = CandidateVerificationStore(records, projectId);
    final workingKey = 'studio.generation.v1.$projectId';
    final candidate = Directory(path.join(canonical, 'candidate'));
    final working = File(path.join(canonical, 'working', 'index.html'));
    final approval = PlanApproval(
      messageIndex: 0,
      content: 'Disposable fixed verification fixture',
      context: nonce,
      approved: true,
      recordedAt: DateTime.utc(2026),
    );
    final receipts = CandidateReceiptFiles();
    final host = NativeGenerationHost(receiptFiles: receipts);
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
        checkpointVersion: 1,
        phase: SourceGenerationPhase.verifying,
        pendingOperation: '',
      );
      stage = 'journal-start';
      final run = await checks.start(snapshot, () {});
      final receiptDirectory = await receipts.prepare(run, () {});
      final verifier = NativeGenerationHost(
        receiptFiles: receipts,
        runOperation: (project, currentOperation) async {
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
          final state = {
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
      await verifier.verify(
        snapshot,
        (current) => checks.checkpoint(current, () {}),
      );
      throw StateError('Target operation did not reach crash boundary.');
    }
    stage = 'recovery-read';
    final beforeFile = File(path.join(canonical, 'before.json'));
    final before =
        jsonDecode(await beforeFile.readAsString()) as Map<String, dynamic>;
    final run = checks.load().runs.single;
    final snapshot = run.snapshot;
    final project = StudioProject(
      id: projectId,
      name: 'Disposable crash fixture',
      description: '',
      type: 'Flutter',
      platforms: const ['web'],
      location: candidate.path,
    );
    stage = 'recovery-controller';
    final controller = SourceCandidateController(
      project: project,
      candidate: snapshot,
      evidence: ApprovedSourceProposal(
        projectId: projectId,
        boardTaskId: 'fixture',
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
      records: records,
      host: host,
      publish: (_, _, _) => throw StateError('Fixture may not promote'),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (controller.receiptsFor(run).isEmpty &&
        controller.receiptHistoryError == null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final retained = controller.receiptsFor(run);
    final currentSources = await NativeGenerationHost.fingerprints(
      snapshot.directory,
      source: true,
    );
    if (controller.historyError != null ||
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
    if (!text.any((value) => value.contains('Candidate checks: verifying')) ||
        !text.any(
          (value) => value.contains('Retained $operation result: exit 0'),
        )) {
      throw StateError('Production candidate view did not render.');
    }
    // Rendering must remain read-only too, including any future view callbacks.
    if (digest(records.getString(checks.key)!) != before['journal'] ||
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
    jsonEncode({'version': 2, 'launch': launch, ...observation}),
    flush: true,
  );
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/imported_commit_context.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/models/imported_commit_copy_observation.dart';
import 'package:asg/models/imported_commit_source_observation.dart';
import 'package:asg/models/imported_commit_proposal.dart';
import 'package:asg/models/imported_commit_proposal_record.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:crypto/crypto.dart';
import 'package:asg/services/imported_commit_copy_host_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_commit_copy_controller.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/imported_commit_proposal_store.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('actual original-commit copy protocol binds Dart intent and preserves source refs index and dirty bytes', () async {
    const python =
        '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12';
    if (!await File(python).exists()) {
      markTestSkipped('Existing Mac fixture interpreter unavailable.');
      return;
    }
    final created = await Directory.systemTemp.createTemp(
      'asg-imported-copy-fixture-',
    );
    final base = Directory(await created.resolveSymbolicLinks());
    try {
      final root = await Directory('${base.path}/source').create();
      final output = await Directory('${base.path}/output').create();
      final bundle = await Directory('${base.path}/helpers').create();
      Future<String> git(List<String> args) async {
        final result = await Process.run(
          '/usr/bin/git',
          [
            '--no-replace-objects',
            '-C',
            root.path,
            '-c',
            'core.hooksPath=/dev/null',
            '-c',
            'user.name=Fixture',
            '-c',
            'user.email=fixture@example.invalid',
            '-c',
            'commit.gpgsign=false',
            ...args,
          ],
          environment: const {
            'PATH': '/usr/bin:/bin',
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_GLOBAL': '/dev/null',
            'GIT_TERMINAL_PROMPT': '0',
          },
          includeParentEnvironment: false,
        );
        expect(result.exitCode, 0, reason: 'Owned Git fixture setup failed.');
        return result.stdout as String;
      }

      await git(['init', '-q']);
      await Directory('${root.path}/lib').create();
      const original = '\ufeff// café\r\n';
      final source = File('${root.path}/lib/main.dart');
      await source.writeAsBytes(utf8.encode(original));
      await File('${root.path}/peer.bin').writeAsBytes([0, 255, 7]);
      await File('${root.path}/pubspec.yaml').writeAsString('name: fixture\n');
      await git(['add', '.']);
      await git(['commit', '-qm', 'synthetic immutable copy']);
      final commit = (await git(['rev-parse', 'HEAD'])).trim();
      final observed = await Process.run(
        python,
        [
          '-I',
          '-S',
          '-B',
          File('tools/imported_commit_source.py').absolute.path,
          '--root',
          root.path,
          '--commit',
          commit,
          '--file',
          'lib/main.dart',
        ],
        environment: const {},
        includeParentEnvironment: false,
      );
      expect(observed.exitCode, 0);
      final readRequest = ImportedCommitReadRequest(
        root: root.path,
        python: python,
        commit: commit,
        selectedPaths: ['lib/main.dart'],
      );
      final context = ImportedCommitContext.capture(
        inspection: ProjectInspection(
          root: root.path,
          packageName: 'fixture',
          dartSdk: '^3.0.0',
          runners: ['web'],
        ),
        requirements: RequirementsBoard(),
        request: readRequest,
        observation: ImportedCommitSourceObservation.fromJson(
          observed.stdout as String,
        ),
      );
      final plan = ImportedPlan(
        text: 'Review original committed baseline copy only',
        context: context.recordJson,
        approved: true,
        recordedAt: DateTime.utc(2026),
      );
      const replacement = '// proposed edit is not applied\n';
      final saved = ImportedCommitProposalRecord.create(
        context: context,
        plan: plan,
        proposal: ImportedCommitProposal.create(
          context: context,
          plan: plan,
          path: 'lib/main.dart',
          replacement: replacement,
        ),
        recordedAt: DateTime.utc(2026),
      );
      final request = ImportedCommitCopyRequest.create(
        saved: saved,
        python: python,
        destination: output.path,
        attemptId: 'a' * 32,
      );
      final compact = ImportedCommitCopyRequest.restore(request.requestJson);
      expect(compact.matches(request), true);
      await source.writeAsString('// keep dirty working bytes\n');
      await File('${root.path}/untracked').writeAsString('keep');
      final before = [
        await git(['rev-parse', 'HEAD']),
        await git(['ls-files', '--stage']),
        await git(['show-ref']),
      ];
      for (final name in [
        'imported_commit_copy.py',
        'imported_commit_source.py',
        'prepare_self_candidate.py',
      ]) {
        await File('tools/$name').copy('${bundle.path}/$name');
      }
      final input = File('${bundle.path}/request.json');
      await input.writeAsString(request.requestJson);
      final copied = await Process.run(
        python,
        [
          '-I',
          '-S',
          '-B',
          '${bundle.path}/imported_commit_copy.py',
          input.path,
        ],
        workingDirectory: bundle.path,
        environment: const {},
        includeParentEnvironment: false,
      ).timeout(const Duration(seconds: 30));
      expect(copied.exitCode, 0, reason: 'Owned baseline copy failed.');
      expect(copied.stderr, '');
      final result = ImportedCommitCopyObservation.fromJson(
        copied.stdout as String,
        request: request,
      );
      expect(result.status, ImportedCommitCopyStatus.prepared);
      expect(result.files, 3);
      expect(
        await File('${result.copyPath}/lib/main.dart').readAsBytes(),
        utf8.encode(original),
      );
      expect(await File('${result.copyPath}/peer.bin').readAsBytes(), [
        0,
        255,
        7,
      ]);
      expect(await File('${result.copyPath}/untracked').exists(), false);
      expect(await source.readAsString(), '// keep dirty working bytes\n');
      expect(await File('${root.path}/untracked').readAsString(), 'keep');
      expect([
        await git(['rev-parse', 'HEAD']),
        await git(['ls-files', '--stage']),
        await git(['show-ref']),
      ], before);
      expect(
        await File('${result.reportedRun(request)}/.asg-imported-copy-pending')
            .exists(),
        false,
      );
      final nativeRequest = ImportedCommitCopyRequest.create(
        saved: saved,
        python: python,
        destination: output.path,
        attemptId: 'b' * 32,
      );
      final host = NativeImportedCommitCopyHost(
        loadAssets: () async => {
          for (final name in [
            'imported_commit_copy.py',
            'imported_commit_source.py',
            'prepare_self_candidate.py',
          ])
            name: await File('tools/$name').readAsString(),
        },
      );
      final nativeResult = await host.prepare(nativeRequest);
      expect(nativeResult.status, ImportedCommitCopyStatus.prepared);
      expect(host.cleanupConfirmed, true);
      expect(host.lastObservation, same(nativeResult));
      expect(nativeResult.copyPath, isNot(result.copyPath));
      expect(nativeResult.fingerprint, result.fingerprint);
      expect(
        await File('${nativeResult.copyPath}/lib/main.dart').readAsBytes(),
        utf8.encode(original),
      );
      expect([
        await git(['rev-parse', 'HEAD']),
        await git(['ls-files', '--stage']),
        await git(['show-ref']),
      ], before);
      await host.dispose();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      var database = await databaseFactoryIo.openDatabase(
        '${base.path}/app.db',
      );
      String? durableCopyFingerprint;
      try {
        final records = await StudioDatabase.migrate(database, preferences);
        await InspectedFolderStore(records).save(root.path);
        await RuntimeSetupStore(records)
            .save(const RuntimeSetup(python: python));
        await records.setString(
          ImportedPlanStore.key(root.path),
          jsonEncode(plan.toJson()),
        );
        await records.setString(
          ImportedCommitProposalStore.key(root.path),
          saved.encode(),
        );
        final controllerHost = NativeImportedCommitCopyHost(
          loadAssets: () async => {
            for (final name in [
              'imported_commit_copy.py',
              'imported_commit_source.py',
              'prepare_self_candidate.py',
            ])
              name: await File('tools/$name').readAsString(),
          },
        );
        final controller = ImportedCommitCopyController(
          root: root.path,
          inspection: ProjectInspection(
            root: root.path,
            packageName: 'fixture',
            dartSdk: '^3.0.0',
            runners: ['web'],
          ),
          expectedHistoryDigest: saved.digest,
          store: ImportedCommitCopyStore(records),
          host: controllerHost,
          attemptId: () => 'c' * 32,
        );
        await controller.load();
        final outputsBeforeReview = await output.list().length;
        await controller.review(output.path);
        expect(await output.list().length, outputsBeforeReview);
        expect(
          records.getString(ImportedCommitCopyStore.key(root.path)),
          isNull,
        );
        await controller.prepare(controller.draft!);
        expect(controller.error, isNull);
        final completed = controller.history!;
        durableCopyFingerprint =
            completed.lastPrepared!.observation!.fingerprint;
        expect(durableCopyFingerprint, nativeResult.fingerprint);
        expect(
          await File(
            '${completed.lastPrepared!.observation!.copyPath}/lib/main.dart',
          ).readAsBytes(),
          utf8.encode(original),
        );
        expect([
          await git(['rev-parse', 'HEAD']),
          await git(['ls-files', '--stage']),
          await git(['show-ref']),
        ], before);
        expect(await source.readAsString(), '// keep dirty working bytes\n');
        expect(
          records.getString(ImportedCommitProposalStore.key(root.path)),
          saved.encode(),
        );
        final durableRaw = completed.recordJson;
        controller.dispose();
        await database.close();
        database = await databaseFactoryIo.openDatabase('${base.path}/app.db');
        final reopened = await StudioDatabase.migrate(database, preferences);
        final idleHost = NativeImportedCommitCopyHost();
        final reopenedController = ImportedCommitCopyController(
          root: root.path,
          store: ImportedCommitCopyStore(reopened),
          host: idleHost,
        );
        final outputCount = await output.list().length;
        await reopenedController.load();
        expect(reopenedController.history!.recordJson, durableRaw);
        expect(idleHost.lastObservation, isNull);
        expect(await output.list().length, outputCount);
        expect(reopenedController.canReview, false);
        reopenedController.dispose();
      } finally {
        await database.close();
      }
      final event = {
        'observedAt': DateTime.now().toUtc().toIso8601String(),
        'requestSha256': request.digest,
        'commit': commit,
        'tree': context.tree,
        'manifestSha256': context.manifestDigest,
        'copyFingerprint': result.fingerprint,
        'originalBytesPreserved': true,
        'proposalApplied': false,
        'dirtyAndUntrackedPreserved': true,
        'headIndexRefsPreserved': true,
        'sourceVerified': false,
        'modelRequests': 0,
        'nativeHostCleanupConfirmed': host.cleanupConfirmed,
        'controllerNativeDatabaseReopened': true,
        'durableCopyFingerprint': durableCopyFingerprint,
        'nativeHostFingerprint': nativeResult.fingerprint,
        'nativeHostRequestSha256': nativeRequest.digest,
        'helperSha256': sha256
            .convert(await File('tools/imported_commit_copy.py').readAsBytes())
            .toString(),
        'requestModelSha256': sha256
            .convert(
              await File('lib/models/imported_commit_copy_request.dart')
                  .readAsBytes(),
            )
            .toString(),
        'resultModelSha256': sha256
            .convert(
              await File('lib/models/imported_commit_copy_observation.dart')
                  .readAsBytes(),
            )
            .toString(),
      };
      await File('/tmp/asg404-immutable-copy-native-components.json')
          .writeAsString(jsonEncode(event));
    } finally {
      await base.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}

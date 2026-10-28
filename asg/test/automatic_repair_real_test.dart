// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sembast/sembast_io.dart';
import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/controllers/source_review_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';

import 'planning_conversation_test.dart' show project;
import 'board_mapped_build_plan_test.dart' show boardContent, sharedContract;

import 'candidate_real_test.dart'
    show installedSdk, RealCandidateFolder, getPreview;

/// Only the initial defect is deterministic; every repair uses real transport.
class BrokenCandidateProposer extends SourceEditProposer {
  bool seeded = false;
  @override
  Future<SourceEditProposal> propose({
    required LocalModelConfig config,
    required String instruction,
    required Map<String, String> originals,
  }) async {
    if (seeded) {
      return super.propose(
        config: config,
        instruction: instruction,
        originals: originals,
      );
    }
    seeded = true;
    final original = originals['lib/main.dart']!;
    return SourceEditProposal.parse({
      'summary': 'Seed an intentional undefined function for repair acceptance',
      'changes': [
        {
          'path': 'lib/main.dart',
          'before': original,
          'after': original.replaceFirst(
            'runApp(',
            'asgMissingFunction();\n  runApp(',
          ),
        },
      ],
    }, originals: originals);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'real local Qwen automatically repairs an actual analyzer failure',
    () async {
      final root = Directory(
        await (await Directory.systemTemp.createTemp('asg-f05-live-'))
            .resolveSymbolicLinks(),
      );
      SharedPreferences.setMockInitialValues({});
      final db = await databaseFactoryIo.openDatabase('${root.path}/studio.db');
      final records = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      var databaseClosed = false;
      SourceGenerationController? controller;
      try {
        await StudioStore(records).save([project]);
        final boards = RequirementsStore(records);
        await boards.save(
          project.id,
          boards.load(project.id),
          RequirementsBoard(
            requirements: [
              ProjectRequirement(
                id: 'R1',
                title: 'Repair undefined function',
                acceptance: 'Remove the undefined asgMissingFunction call in lib/main.dart if present. Preserve all existing imports, initialization, asset loading, title and remaining code. All checks must pass',
              ),
            ],
            tasks: [
              DevelopmentTask(
                id: 'Tstarter',
                requirementId: 'R1',
                title: 'Repair the undefined asgMissingFunction call in lib/main.dart while preserving everything else',
              ),
            ],
          ),
        );
        final approvals = PlanApprovalStore(records);
        final plans = [
          ChatMessage(
            role: 'assistant',
            content: boardContent(sharedContract()),
            planContext: approvals.contextFor(project),
          ),
        ];
        await ConversationStore(records).save(project.id, plans);
        await approvals.save(project, plans, true);
        final definition = ApplicationStore(records).load(project).definition;
        controller = SourceGenerationController(
          project: project,
          definition: definition,
          store: SourceGenerationStore(records),
          host: NativeGenerationHost(
            loadAsset: (name) => File(name).readAsString(),
          ),
        );
        expect(
          await controller.generate(
            parent: root.path,
            name: 'working',
            sdk: installedSdk(),
            python: 'python3',
            approved: true,
          ),
          isTrue,
          reason: controller.error,
        );
        await controller.startPreview();
        final oldPreview = controller.preview!;
        final working = controller.result!;
        final source = File('${working.directory}/lib/main.dart');
        final original = await source.readAsString();
        final oldJs = await getPreview(oldPreview.resolve('main.dart.js'));
        final review = SourceReviewController(
          project: project,
          generated: working,
          records: records,
          proposer: ApprovedSourceProposer(
            records,
            proposer: BrokenCandidateProposer(),
          ),
          publishCandidate: (value, host, authorize) =>
              controller!.promoteCandidate(
                value,
                host,
                authorize,
                expectedWorking: working,
              ),
          folderPicker: RealCandidateFolder(root.path),
          createCandidateHost: () => NativeGenerationHost(
            loadAsset: (name) => File(name).readAsString(),
          ),
        );
        try {
          await review.request('Tstarter', ['lib/main.dart']);
          expect(review.error, isNull);
          expect(review.proposal, isNotNull);
          expect(
            review.proposal!.proposal.changes.single.after,
            contains('asgMissingFunction();'),
          );
          await review.selectCandidateParent();
          await review.prepareCandidate();
          final broken = review.candidateSession!;
          await broken.verify(approved: true);
          expect(
            broken.result.phase,
            SourceGenerationPhase.failed,
            reason: broken.error,
          );
          expect(broken.result.steps.last.operation, 'analyze');
          expect(broken.result.steps.last.exitCode, greaterThan(0));
          expect(
            broken.result.steps.last.output,
            contains('asgMissingFunction'),
          );
          final failure = jsonEncode(broken.result.toJson());
          expect(await source.readAsString(), original);
          expect(await getPreview(oldPreview.resolve('main.dart.js')), oldJs);
          await review.selectCandidateParent();
          expect(review.canStartAutomaticRepair, isTrue);
          await review.runAutomaticRepairs(['lib/main.dart'], approved: true);
          expect(review.error, isNull, reason: review.error);
          final candidate = review.candidateSession!;
          expect(
            candidate.result.phase,
            SourceGenerationPhase.ready,
            reason: candidate.error ?? candidate.result.error,
          );
          expect(candidate.result.steps.length, 4);
          expect(
            candidate.result.steps.every((step) => step.succeeded),
            isTrue,
          );
          expect(await getPreview(oldPreview.resolve('main.dart.js')), oldJs);
          expect(await source.readAsString(), original);
          expect(
            await candidate.promote(approved: true),
            isTrue,
            reason: candidate.error,
          );
          final refreshed = controller.preview!;
          expect(refreshed, isNot(oldPreview));
          final js = await getPreview(refreshed.resolve('main.dart.js'));
          expect(js, isNotEmpty);
          final corrected = await File(
            '${candidate.result.directory}/lib/main.dart',
          ).readAsString();
          expect(corrected, isNot(contains('asgMissingFunction();')));
          final attempts = RepairAttemptStore(
            records,
            project.id,
          ).load().attempts;
          expect(attempts.length, inInclusiveRange(1, 3));
          expect(
            attempts.every(
              (a) => a.category == 'analyze' && a.proposal != null,
            ),
            isTrue,
          );
          expect(jsonEncode(attempts.first.failure.snapshot.toJson()), failure);
          final runs = CandidateVerificationStore(
            records,
            project.id,
          ).load().runs;
          expect(runs.length, attempts.length + 1);
          expect(runs.every((r) => r.finished), isTrue);
          expect(runs.last.snapshot.phase, SourceGenerationPhase.ready);
          expect(await controller.verifyAgain(approved: true), isFalse);
          expect(await getPreview(refreshed.resolve('main.dart.js')), js);
          expect(
            SourceGenerationStore(records).load(project.id)!.directory,
            candidate.result.directory,
          );
          expect(
            SourceGenerationStore(
              records,
              prefix: 'studio.generationPrevious.v1.',
            ).load(project.id)!.directory,
            working.directory,
          );
          expect(await source.readAsString(), original);
          debugPrint(
            'F05_REAL_ACCEPTANCE: actual analyzer failure, real Qwen automatic correction, durable attempts, confined ${candidate.result.steps.map((s) => '${s.operation}=${s.exitCode}').join(', ')}, atomic promotion, refreshed HTTP200 preview.',
          );
          if (const bool.fromEnvironment('ASG_BROWSER_REVIEW')) {
            debugPrint('F05_PREVIEW=$refreshed');
            await Future<void>.delayed(const Duration(minutes: 2));
          }
        } finally {
          review.dispose();
        }
        final savedAttempts = records.getString(
          RepairAttemptStore(records, project.id).key,
        );
        final savedChecks = records.getString(
          CandidateVerificationStore(records, project.id).key,
        );
        expect(savedAttempts, isNotNull);
        expect(savedChecks, isNotNull);
        controller.dispose();
        controller = null;
        await db.close();
        databaseClosed = true;
        final reopened = await databaseFactoryIo.openDatabase(
          '${root.path}/studio.db',
        );
        try {
          final restored = await StudioDatabase.migrate(
            reopened,
            await SharedPreferences.getInstance(),
          );
          expect(
            restored.getString(RepairAttemptStore(restored, project.id).key),
            savedAttempts,
          );
          expect(
            restored.getString(
              CandidateVerificationStore(restored, project.id).key,
            ),
            savedChecks,
          );
          final restoredAttempts = RepairAttemptStore(
            restored,
            project.id,
          ).load().attempts;
          expect(restoredAttempts.length, inInclusiveRange(1, 3));
          expect(
            restoredAttempts.first.failure.snapshot.steps.last.exitCode,
            greaterThan(0),
          );
          expect(
            restoredAttempts.first.failure.snapshot.steps.last.output,
            contains('asgMissingFunction'),
          );
          expect(
            CandidateVerificationStore(
              restored,
              project.id,
            ).load().runs.last.snapshot.phase,
            SourceGenerationPhase.ready,
          );
          expect(
            SourceGenerationStore(restored).load(project.id)!.confined,
            isTrue,
          );
          expect(
            SourceGenerationStore(
              restored,
              prefix: 'studio.generationPrevious.v1.',
            ).load(project.id)!.directory,
            working.directory,
          );
        } finally {
          await reopened.close();
        }
      } finally {
        controller?.dispose();
        if (!databaseClosed) await db.close();
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('ASG_REAL_INFERENCE'),
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

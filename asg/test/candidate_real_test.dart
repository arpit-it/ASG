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
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/services/requirement_check_report_store.dart';

import 'support/acceptance_provenance.dart';

import 'planning_conversation_test.dart' show project, ControlledRecords;
import 'board_mapped_build_plan_test.dart' show boardContent, sharedContract;

String installedSdk() {
  final configured =
      Platform.environment['ASG_FLUTTER_SDK'] ??
      Platform.environment['FLUTTER_ROOT'];
  if (configured != null) return configured;
  var ancestor = File(Platform.resolvedExecutable).parent;
  while (ancestor.parent.path != ancestor.path) {
    if (File('${ancestor.path}/bin/flutter').existsSync()) return ancestor.path;
    ancestor = ancestor.parent;
  }
  throw StateError('Set ASG_FLUTTER_SDK to an initialized cached SDK.');
}

class RealCandidateFolder extends FolderPicker {
  RealCandidateFolder(this.parent);
  final String parent;
  @override
  bool get supported => true;
  @override
  Future<String?> pick() async => parent;
}

Future<String> getPreview(Uri uri) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(uri)).close();
    expect(response.statusCode, 200);
    return utf8.decode(
      await response.fold<List<int>>([], (all, part) => all..addAll(part)),
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'confined generated fixture executes fixed tools',
    () async {
      final root = await Directory.systemTemp.createTemp('asg-confined-real-');
      final host = NativeGenerationHost(
        loadAsset: (name) => File(name).readAsString(),
      );
      try {
        final original = await host.generate(
          project: project,
          definition: ApplicationStore(ControlledRecords())
              .load(project)
              .definition,
          parent: await root.resolveSymbolicLinks(),
          name: 'fixture',
          sdk: installedSdk(),
          python: 'python3',
        );
        final candidate = GeneratedProject.fromJson({
          ...original.toJson(),
          'confinementVersion': 1,
        });
        final ready = await host.verify(candidate, (event) async {
          if (event.steps.isNotEmpty && event.pendingOperation.isEmpty) {
            debugPrint(
              '${event.steps.last.operation}: ${event.steps.last.output}',
            );
          }
        });
        expect(ready.phase, SourceGenerationPhase.ready, reason: ready.error);
      } finally {
        await host.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('ASG_REAL_GENERATION'),
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test(
    'real local Qwen source candidate verifies promotes and refreshes actual preview',
    () async {
      final root = Directory(
        await (await Directory.systemTemp.createTemp('asg-f04-live-'))
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
                title: 'Visible source edit',
                acceptance: 'In lib/main.dart replace runApp(GeneratedApp(definition: definition)); with runApp(GeneratedApp(definition: AppDefinition(title: "F04 Model Verified", theme: definition.theme, elements: definition.elements)));. Keep all imports, JSON asset loading, initialization and other code unchanged. All checks and refreshed preview must pass.',
              ),
            ],
            tasks: [
              DevelopmentTask(
                id: 'Tstarter',
                requirementId: 'R1',
                title: 'Change only the title in lib/main.dart to F04 Model Verified as specified in requirement acceptance. Keep existing loading code and imports.',
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
        final review = controller.createSourceReview(
          folderPicker: RealCandidateFolder(root.path),
          createCandidateHost: () => NativeGenerationHost(
            loadAsset: (name) => File(name).readAsString(),
          ),
        )!;
        try {
          await review.request('Tstarter', ['lib/main.dart']);
          expect(review.error, isNull);
          expect(review.proposal, isNotNull);
          expect(
            review.proposal!.proposal.changes.single.after,
            contains('F04 Model Verified'),
          );
          expect(
            review.proposal!.proposal.changes.single.after,
            isNot(original),
          );
          await review.selectCandidateParent();
          await review.prepareCandidate();
          expect(review.error, isNull);
          final failedCandidate = review.candidateSession!;
          // Hash refusal is a real failure before unreviewed source can execute.
          await File('${failedCandidate.result.directory}/lib/main.dart')
              .writeAsString('unreviewed modification');
          await failedCandidate.verify(approved: true);
          expect(failedCandidate.result.phase, SourceGenerationPhase.failed);
          expect(await source.readAsString(), original);
          expect(await getPreview(oldPreview.resolve('main.dart.js')), oldJs);
          expect(
            SourceGenerationStore(records).load(project.id)!.directory,
            working.directory,
          );
          await review.selectCandidateParent();
          await review.prepareCandidate();
          final candidate = review.candidateSession!;
          await candidate.verify(approved: true);
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
          expect(js, contains('F04 Model Verified'));
          expect(js, isNot(oldJs));
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
            'F04_REAL_ACCEPTANCE: real Qwen proposal, hash-failure preservation, confined ${candidate.result.steps.map((s) => '${s.operation}=${s.exitCode}').join(', ')}, atomic promotion, refreshed HTTP200 preview.',
          );
          if (const bool.fromEnvironment('ASG_BROWSER_REVIEW')) {
            debugPrint('F04_PREVIEW=$refreshed');
            await Future<void>.delayed(const Duration(minutes: 2));
          }
        } finally {
          review.dispose();
        }
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
          final provenance = acceptanceProvenanceLine(
            RequirementCheckReportStore(restored).load(project),
            scenario: 'reviewed-candidate',
          );
          if (provenance != null) debugPrint(provenance);
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

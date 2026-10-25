import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/source_review_controller.dart';
import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/services/candidate_repair_evidence.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/generation_host.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/views/source_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart' show seed, originals, response;
import 'planning_conversation_test.dart' show project, tick;
import 'source_candidate_controller_test.dart'
    show AtomicRecords, FailedCheckHost;
import 'source_edit_proposer_test.dart' show FakeProvider;
import 'source_generation_controller_test.dart' show FixtureHost;

class CandidateFolderPicker extends FolderPicker {
  @override
  bool get supported => true;
  @override
  Future<String?> pick() async => '/candidates';
}

class ReviewCandidateHost extends FixtureHost {
  @override
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  }) async {
    var value = project.copy(phase: SourceGenerationPhase.verifying);
    await progress(value);
    for (final task in project.tasks!) {
      value = value.copy(
        steps: [
          ...value.steps,
          GenerationStep(
            operation: task.operation.name,
            exitCode: 0,
            output: 'fixture',
          ),
        ],
      );
      await progress(value);
    }
    value = value.copy(
      phase: SourceGenerationPhase.ready,
      outputs: {'index.html': '0' * 64, 'main.dart.js': '0' * 64},
    );
    await progress(value);
    return value;
  }
}

class DelayedRepairHost extends ReviewCandidateHost {
  final gate = Completer<void>();
  var stops = 0;
  @override
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  }) async {
    await progress(project.copy(phase: SourceGenerationPhase.verifying));
    await gate.future;
    return super.verify(project, progress);
  }

  @override
  void cancelVerification() {
    stops++;
    if (!gate.isCompleted) gate.complete();
  }
}

void main() {
  late AtomicRecords records;
  late FakeProvider provider;
  late SourceReviewController controller;
  var reads = 0;
  SourceReviewController create({
    Completer<Map<String, String>>? capture,
    SourceCandidatePreparer? prepare,
    CandidatePromotion? publish,
    GenerationHost Function()? createHost,
    SourceSnapshotReader? read,
  }) => SourceReviewController(
    project: project,
    generated: GeneratedProject(
      directory: '/saved',
      sdk: '',
      python: '',
      sources: {'lib/main.dart': 'hash'},
    ),
    records: records,
    prepareCandidate: prepare,
    publishCandidate: publish,
    createCandidateHost: createHost ?? () => ReviewCandidateHost(),
    folderPicker: CandidateFolderPicker(),
    proposer: ApprovedSourceProposer(
      records,
      proposer: SourceEditProposer(createProvider: (_) => provider),
    ),
    readSnapshot:
        read ??
        (_, paths) async {
          reads++;
          expect(paths, ['lib/main.dart']);
          return capture == null ? originals : capture.future;
        },
  );
  setUp(() async {
    records = AtomicRecords();
    await seed(records);
    provider = FakeProvider();
    reads = 0;
    controller = create();
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });

  for (final repair in [false, true]) {
    for (final stage in ['Reading recorded source', 'Requesting local model']) {
      for (final action in [
        'stop',
        'dispose',
        'working',
        'approval',
        if (repair) 'stop then verify',
      ]) {
        test('progress boundary $stage $action (repair: $repair)', () async {
          controller.dispose();
          controller = create(
            createHost: () => FailedCheckHost(),
            publish: (_, host, guard) async => throw StateError('No promotion'),
            prepare:
                ({
                  required project,
                  required generated,
                  required evidence,
                  required records,
                  required parent,
                  required checkActive,
                }) async {
                  checkActive();
                  return GeneratedProject(
                    directory: '/candidate/boundary',
                    sdk: '/sdk',
                    python: 'python3',
                    confined: true,
                    sources: GenerationInput(
                      project,
                      ApplicationStore(records).load(project).definition,
                    ).fingerprints,
                    approval: evidence.approval,
                    tasks: BuildPlan.parse(
                      evidence.approval.content,
                      board: RequirementsStore(records).load(project.id),
                    ).tasks,
                  );
                },
          );
          if (repair) {
            final initial = controller.request('Tanalyze', ['lib/main.dart']);
            await tick();
            provider.stream.add(response());
            await provider.stream.close();
            await initial;
            await controller.selectCandidateParent();
            await controller.prepareCandidate();
            await controller.candidateSession!.verify(approved: true);
            expect(controller.canRequestRepair, isTrue);
          }
          final retained = controller.candidate;
          final workingKey = 'studio.generation.v1.${project.id}';
          final working = records.getString(workingKey);
          final checks = records.getString(
            'studio.candidateChecks.v1.${project.id}',
          );
          final attempts = records.getString(
            'studio.repairAttempts.v1.${project.id}',
          );
          final beforeReads = reads;
          provider = FakeProvider();
          var triggered = false;
          void listener() {
            if (triggered || !controller.status.startsWith(stage)) return;
            triggered = true;
            switch (action) {
              case 'stop' || 'stop then verify':
                unawaited(controller.cancel());
              case 'dispose':
                controller.dispose();
              case 'working':
                records.values[workingKey] = 'changed';
              case 'approval':
                records.values['studio.planApproval.v1.${project.id}'] = '{}';
            }
          }

          controller.addListener(listener);
          final pending = repair
              ? controller.requestRepair(['lib/main.dart'])
              : controller.request('Tanalyze', ['lib/main.dart']);
          await tick();
          // Close even if broken code dispatches, so observations fail without
          // hanging on a model response.
          provider.stream.add(response());
          unawaited(provider.stream.close());
          await pending;
          expect(triggered, isTrue);
          expect(provider.prompt, isNull);
          expect(
            reads,
            beforeReads + (stage == 'Reading recorded source' ? 0 : 1),
          );
          expect(controller.busy, isFalse);
          expect(controller.candidate, same(retained));
          expect(
            records.getString('studio.candidateChecks.v1.${project.id}'),
            checks,
          );
          expect(
            records.getString('studio.repairAttempts.v1.${project.id}'),
            attempts,
          );
          if (action != 'working') {
            expect(records.getString(workingKey), working);
          }
          if (action == 'stop then verify') {
            expect(controller.status, contains('cancelled'));
            controller.removeListener(listener);
            final statuses = <String>[];
            controller.addListener(() => statuses.add(controller.status));
            await controller.candidateSession!.verify(approved: true);
            expect(
              statuses,
              contains(contains('Verifying isolated candidate')),
            );
            expect(controller.status, contains('Candidate checks stopped'));
            expect(controller.status, isNot(contains('cancelled')));
          }
          if (action == 'stop') {
            expect(controller.status, contains('cancelled'));
            controller.removeListener(listener);
            provider = FakeProvider();
            final retry = repair
                ? controller.requestRepair(['lib/main.dart'])
                : controller.request('Tanalyze', ['lib/main.dart']);
            await tick();
            expect(provider.prompt, isNotNull);
            provider.stream.add(response());
            await provider.stream.close();
            await retry;
            expect(controller.proposal, isNotNull);
          }
        });
      }
    }
  }

  testWidgets(
    'saved failure repair action is readable at 320px and 200 percent text',
    (tester) async {
      controller.dispose();
      controller = create(
        createHost: () => FailedCheckHost(),
        publish: (_, host, guard) async => Uri.parse('http://127.0.0.1:1/'),
        prepare:
            ({
              required project,
              required generated,
              required evidence,
              required records,
              required parent,
              required checkActive,
            }) async => GeneratedProject(
              directory: '/candidates/failure',
              sdk: '/sdk',
              python: 'python3',
              confined: true,
              sources: GenerationInput(
                project,
                ApplicationStore(records).load(project).definition,
              ).fingerprints,
              approval: evidence.approval,
              tasks: BuildPlan.parse(
                evidence.approval.content,
                board: RequirementsStore(records).load(project.id),
              ).tasks,
            ),
      );
      await tester.runAsync(() async {
        final pending = controller.request('Tanalyze', ['lib/main.dart']);
        await tick();
        provider.stream.add(response());
        await provider.stream.close();
        await pending;
        await controller.selectCandidateParent();
        await controller.prepareCandidate();
        await controller.candidateSession!.verify(approved: true);
      });
      expect(controller.canRequestRepair, isTrue);
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SourceReviewScreen(controller: controller),
        ),
      );
      final action = find.text('Request repair proposal from saved failure');
      await tester.scrollUntilVisible(
        action,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining(
          'This does not apply edits or rerun checks automatically.',
        ),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining(
          'This does not apply edits or rerun checks automatically.',
        ),
        findsOneWidget,
      );
      final attempts = RepairAttemptStore(records, project.id);
      final failure = requireRepairFailure(
        records,
        project.id,
        controller.candidate!,
      );
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() async {
          await RepairAttemptStore(records, project.id).reserve(failure, () {});
        });
      }
      expect(attempts.load().attempts.length, 3);
      controller.refreshApproval();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        action,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.ancestor(of: action, matching: find.byType(FilledButton)),
      );
      expect(button.onPressed, isNull);
      await tester.scrollUntilVisible(
        find.textContaining('Repair budget exhausted:'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Repair budget exhausted:'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('repair reads failed candidate and prepares a new reviewed copy while retaining working output', () async {
    controller.dispose();
    final bases = <String>[];
    final captures = <String>[];
    controller = create(
      createHost: () => FailedCheckHost(),
      publish: (_, host, guard) async => Uri.parse('http://127.0.0.1:1/'),
      read: (source, paths) async {
        captures.add(source.directory);
        return source.directory == '/saved'
            ? originals
            : {'lib/main.dart': 'void main() { broken; }'};
      },
      prepare:
          ({
            required project,
            required generated,
            required evidence,
            required records,
            required parent,
            required checkActive,
          }) async {
            checkActive();
            bases.add(generated.directory);
            return GeneratedProject(
              directory: '/candidates/copy-${bases.length}',
              sdk: '/sdk',
              python: 'python3',
              confined: true,
              sources: {
                ...GenerationInput(
                  project,
                  ApplicationStore(records).load(project).definition,
                ).fingerprints,
                'lib/main.dart': 'a' * 64,
              },
              approval: evidence.approval,
              tasks: BuildPlan.parse(
                evidence.approval.content,
                board: RequirementsStore(records).load(project.id),
              ).tasks,
            );
          },
    );
    final first = controller.request('Tanalyze', ['lib/main.dart']);
    await tick();
    provider.stream.add(response());
    await provider.stream.close();
    await first;
    await controller.selectCandidateParent();
    await controller.prepareCandidate();
    await controller.candidateSession!.verify(approved: true);
    expect(controller.canRequestRepair, isTrue);
    final workingRecord = records.getString(
      'studio.generation.v1.${project.id}',
    );
    final checks = records.getString('studio.candidateChecks.v1.${project.id}');
    provider = FakeProvider();
    final pending = controller.requestRepair(['lib/main.dart']);
    await tick();
    expect(controller.busy, isTrue);
    expect(controller.status, contains('local model'));
    expect(provider.prompt, contains('Undefined name at lib/main.dart:7'));
    expect(provider.prompt, contains('broken;'));
    provider.stream.add(
      jsonEncode({
        'summary': 'Fix name',
        'changes': [
          {
            'path': 'lib/main.dart',
            'before': 'void main() { broken; }',
            'after': 'void main() {}',
          },
        ],
      }),
    );
    await provider.stream.close();
    await pending;
    expect(controller.proposal!.repairRun, isNotNull);
    expect(captures, ['/saved', '/candidates/copy-1']);
    final reviewed = controller.proposal;
    final failedCandidate = controller.candidate;
    provider = FakeProvider();
    final failedRetry = controller.requestRepair(['lib/main.dart']);
    await tick();
    expect(controller.status, contains('Requesting local model'));
    provider.stream.addError(StateError('offline repair retry'));
    await provider.stream.close();
    await failedRetry;
    expect(controller.busy, isFalse);
    expect(controller.status, contains('Source proposal failed'));
    expect(controller.status, isNot(contains('Requesting')));
    expect(controller.error, contains('offline repair retry'));
    expect(controller.proposal, same(reviewed));
    expect(controller.candidate, same(failedCandidate));
    final store = RepairAttemptStore(records, project.id);
    await store.reserve(
      requireRepairFailure(records, project.id, controller.candidate!),
      () {},
    );
    expect(controller.hasRepairFailure, isTrue);
    expect(controller.canRequestRepair, isFalse);
    expect(controller.repairUsage['analyze'], 3);
    final captureCount = captures.length;
    provider = FakeProvider();
    await controller.requestRepair(['lib/main.dart']);
    expect(controller.error, contains('budget exhausted'));
    expect(captures.length, captureCount);
    expect(provider.prompt, isNull);
    expect(controller.repairHistory.length, 3);
    final retained = records.values[store.key]!;
    records.values[store.key] = '{}';
    expect(controller.canRequestRepair, isFalse);
    await controller.requestRepair(['lib/main.dart']);
    expect(controller.error, contains('unreadable'));
    expect(captures.length, captureCount);
    expect(records.values[store.key], '{}');
    records.values[store.key] = retained;
    await controller.selectCandidateParent();
    await controller.prepareCandidate();
    expect(controller.error, isNull);
    expect(bases, ['/saved', '/candidates/copy-1']);
    expect(controller.candidate!.directory, '/candidates/copy-2');
    expect(controller.proposal!.repairRun, isNull);
    // New candidate verification must not depend on the previous latest journal.
    await controller.candidateSession!.verify(approved: true);
    expect(controller.candidateSession!.error, isNull);
    expect(controller.candidateSession!.history.length, 2);
    expect(
      checks,
      isNot(records.getString('studio.candidateChecks.v1.${project.id}')),
    );
    expect(
      records.getString('studio.generation.v1.${project.id}'),
      workingRecord,
    );
  });

  test(
    'candidate consent, duplicate guard, cancellation and retained output',
    () async {
      controller.dispose();
      final done = Completer<GeneratedProject>();
      var calls = 0;
      controller = create(
        prepare:
            ({
              required project,
              required generated,
              required evidence,
              required records,
              required parent,
              required checkActive,
            }) async {
              calls++;
              expect(parent, '/candidates');
              checkActive();
              return done.future;
            },
      );
      await controller.prepareCandidate();
      expect(calls, 0);
      final request = controller.request('Tanalyze', ['lib/main.dart']);
      await tick();
      provider.stream.add(response());
      await provider.stream.close();
      await request;
      await controller.prepareCandidate();
      expect(calls, 0);
      await controller.selectCandidateParent();
      final saved = controller.generated;
      final writes = records.writes;
      final pending = controller.prepareCandidate();
      await controller.prepareCandidate();
      expect(calls, 1);
      await controller.cancel();
      final candidate = GeneratedProject(
        directory: '/candidates/new',
        sdk: '',
        python: '',
        sources: {},
      );
      done.complete(candidate);
      await pending;
      expect(controller.candidate, same(candidate));
      expect(controller.generated, same(saved));
      expect(records.writes, writes);
      expect(controller.error, contains('did not complete'));
      expect(controller.status, contains('cancelled'));
    },
  );

  test(
    'candidate success, failure, withdrawal and disposal are truthful',
    () async {
      for (final outcome in ['success', 'failure', 'withdraw', 'dispose']) {
        controller.dispose();
        records = AtomicRecords();
        await seed(records);
        provider = FakeProvider();
        final done = Completer<GeneratedProject>();
        controller = create(
          prepare: ({
            required project,
            required generated,
            required evidence,
            required records,
            required parent,
            required checkActive,
          }) => done.future,
        );
        final request = controller.request('Tanalyze', ['lib/main.dart']);
        await tick();
        provider.stream.add(response());
        await provider.stream.close();
        await request;
        await controller.selectCandidateParent();
        final pending = controller.prepareCandidate();
        var updates = 0;
        controller.addListener(() => updates++);
        if (outcome == 'withdraw') {
          await PlanApprovalStore(
            records,
          ).save(project, ConversationStore(records).load(project.id), false);
        }
        if (outcome == 'dispose') controller.dispose();
        if (outcome == 'failure') {
          done.completeError(
            StateError('Retained partial candidate: /partial'),
          );
        } else {
          done.complete(
            GeneratedProject(
              directory: '/new',
              sdk: '',
              python: '',
              sources: {},
            ),
          );
        }
        await pending;
        expect(controller.busy, isFalse);
        if (outcome == 'success') {
          expect(controller.candidateParent, isNull);
          expect(controller.status, contains('Unverified candidate prepared'));
        } else if (outcome == 'failure') {
          expect(controller.error, contains('/partial'));
          expect(controller.status, contains('failed'));
        } else if (outcome == 'withdraw') {
          expect(controller.error, contains('did not complete'));
          expect(controller.candidate!.directory, '/new');
          expect(controller.proposal, isNull);
        } else {
          expect(updates, 0);
          expect(controller.candidate, isNull);
        }
        if (outcome == 'withdraw') {
          final error = controller.error;
          await controller.prepareCandidate();
          expect(controller.error, isNot(error));
        }
      }
    },
  );

  for (final outcome in [
    'success',
    'failure',
    'cancel',
    'withdraw',
    'working',
    'dispose',
    'copy failure',
    'listener stop',
  ]) {
    test('reviewed repair automatic checks: $outcome', () async {
      controller.dispose();
      var copies = 0, hosts = 0;
      Completer<void>? gate;
      controller = create(
        createHost: () {
          hosts++;
          return hosts == 1 || outcome == 'failure'
              ? FailedCheckHost()
              : ReviewCandidateHost();
        },
        publish: (_, host, guard) async =>
            throw StateError('Unexpected promotion'),
        prepare:
            ({
              required project,
              required generated,
              required evidence,
              required records,
              required parent,
              required checkActive,
            }) async {
              checkActive();
              copies++;
              await gate?.future;
              if (copies == 2 && outcome == 'copy failure') {
                throw StateError('copy failed /partial');
              }
              return GeneratedProject(
                directory: '/candidate/$copies',
                sdk: '/sdk',
                python: 'python3',
                confined: true,
                sources: GenerationInput(
                  project,
                  ApplicationStore(records).load(project).definition,
                ).fingerprints,
                approval: evidence.approval,
                tasks: BuildPlan.parse(
                  evidence.approval.content,
                  board: RequirementsStore(records).load(project.id),
                ).tasks,
              );
            },
      );
      Future<void> respond({bool repair = false}) async {
        provider = FakeProvider();
        final pending = repair
            ? controller.requestRepair(['lib/main.dart'])
            : controller.request('Tanalyze', ['lib/main.dart']);
        await tick();
        provider.stream.add(response());
        await provider.stream.close();
        await pending;
        expect(controller.error, isNull);
      }

      await respond();
      await controller.selectCandidateParent();
      await controller.applyReviewedRepair(approved: true);
      expect(copies, 0); // An ordinary proposal cannot grant repair consent.
      await controller.prepareCandidate();
      await controller.candidateSession!.verify(approved: true);
      await respond(repair: true);
      expect(controller.proposal!.repairRun, isNotNull);
      await controller.applyReviewedRepair(approved: true);
      expect(copies, 1); // No parent selected for this diff.
      await controller.selectCandidateParent();
      await controller.applyReviewedRepair(approved: false);
      expect(copies, 1);
      final previous = controller.candidateSession;
      final working = records.getString('studio.generation.v1.${project.id}');
      gate = Completer<void>();
      final pending = controller.applyReviewedRepair(approved: true);
      await controller.applyReviewedRepair(approved: true);
      expect(copies, 2); // Duplicate submissions cannot prepare another copy.
      if (outcome == 'cancel') await controller.cancel();
      if (outcome == 'withdraw') {
        await PlanApprovalStore(records)
            .save(project, ConversationStore(records).load(project.id), false);
      }
      if (outcome == 'working') {
        records.values['studio.generation.v1.${project.id}'] = 'changed';
      }
      if (outcome == 'dispose') controller.dispose();
      if (outcome == 'listener stop') {
        controller.addListener(() {
          if (controller.status.startsWith('Verifying repaired candidate')) {
            unawaited(controller.cancel());
          }
        });
      }
      gate.complete();
      await pending;
      final runs = CandidateVerificationStore(records, project.id).load().runs;
      if (outcome == 'success' || outcome == 'failure') {
        expect(runs.length, 2);
        expect(hosts, 2);
        expect(
          controller.candidate!.phase,
          outcome == 'success'
              ? SourceGenerationPhase.ready
              : SourceGenerationPhase.failed,
        );
        expect(
          runs.last.snapshot.steps.last.exitCode,
          outcome == 'success' ? 0 : 65,
        );
        if (outcome == 'success') {
          expect(
            runs.last.snapshot.steps.map((s) => s.operation),
            controller.candidate!.tasks!.map((t) => t.operation.name),
          );
        } else {
          expect(controller.status, contains('stopped'));
          expect(
            runs.last.snapshot.steps.last.output,
            contains('Undefined name'),
          );
        }
      } else {
        expect(runs.length, 1);
        if (outcome != 'listener stop') {
          expect(controller.candidateSession, same(previous));
        }
      }
      expect(controller.promoted, isFalse);
      if (outcome != 'working') {
        expect(
          records.getString('studio.generation.v1.${project.id}'),
          working,
        );
      }
    });
  }

  testWidgets(
    'reviewed repair rerun shows consent, progress and Stop at narrow enlarged text',
    (tester) async {
      controller.dispose();
      var copies = 0;
      final delayed = DelayedRepairHost();
      controller = create(
        createHost: () => copies == 1 ? FailedCheckHost() : delayed,
        publish: (_, host, guard) async =>
            throw StateError('Unexpected promotion'),
        prepare:
            ({
              required project,
              required generated,
              required evidence,
              required records,
              required parent,
              required checkActive,
            }) async {
              checkActive();
              copies++;
              return GeneratedProject(
                directory: '/candidate/$copies',
                sdk: '/sdk',
                python: 'python3',
                confined: true,
                sources: GenerationInput(
                  project,
                  ApplicationStore(records).load(project).definition,
                ).fingerprints,
                approval: evidence.approval,
                tasks: BuildPlan.parse(
                  evidence.approval.content,
                  board: RequirementsStore(records).load(project.id),
                ).tasks,
              );
            },
      );
      await tester.runAsync(() async {
        for (final repair in [false, true]) {
          provider = FakeProvider();
          final pending = repair
              ? controller.requestRepair(['lib/main.dart'])
              : controller.request('Tanalyze', ['lib/main.dart']);
          await tick();
          provider.stream.add(response());
          unawaited(provider.stream.close());
          await pending;
          await controller.selectCandidateParent();
          if (!repair) {
            await controller.prepareCandidate();
            await controller.candidateSession!.verify(approved: true);
          }
        }
      });
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SourceReviewScreen(controller: controller),
        ),
      );
      const action = 'Apply reviewed repair and rerun checks';
      const consent = 'I approve applying this repair and confined checks';
      Future<void> reveal(String text, double delta) async {
        await tester.scrollUntilVisible(
          find.text(text),
          delta,
          maxScrolls: 150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.text(text));
        await tester.pumpAndSettle();
      }

      await reveal(action, 300);
      FilledButton button() => tester.widget<FilledButton>(
        find.ancestor(
          of: find.text(action),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button().onPressed, isNull);
      await reveal(consent, -200);
      await tester.tap(find.text(consent));
      await tester.pumpAndSettle();
      await reveal(action, 200);
      expect(button().onPressed, isNotNull);
      await tester.tap(find.text(action));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(controller.busy, isTrue);
      expect(controller.candidateSession!.busy, isTrue);
      const stop = 'Stop candidate verification';
      await tester.scrollUntilVisible(
        find.text(stop),
        -300,
        maxScrolls: 150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text(stop));
      await tester.pump();
      expect(find.text(stop), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      await tester.tap(find.text(stop));
      await tester.pumpAndSettle();
      expect(delayed.stops, greaterThan(0));
      expect(controller.busy, isFalse);
      expect(controller.candidate!.phase, SourceGenerationPhase.failed);
      expect(controller.promoted, isFalse);
      final runs = CandidateVerificationStore(records, project.id).load().runs;
      expect(runs.length, 2);
      expect(runs.last.snapshot.steps, isEmpty);
      expect(runs.last.snapshot.phase, SourceGenerationPhase.failed);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('request binds selected files and task without durable writes; stale evidence hides', () async {
    final writes = records.writes;
    final pending = controller.request('Tanalyze', ['lib/main.dart']);
    await tick();
    expect(controller.busy, isTrue);
    expect(controller.status, contains('local model'));
    await controller.request('Tanalyze', ['lib/main.dart']);
    expect(reads, 1);
    provider.stream.add(response());
    await provider.stream.close();
    await pending;
    expect(
      controller.proposal!.proposal.changes.single.before,
      originals.values.single,
    );
    expect(records.writes, writes);
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), false);
    expect(controller.proposal, isNull);
    expect(controller.stale, isTrue);
    controller.refreshApproval();
    expect(controller.tasks, isEmpty);
  });

  test(
    'invalid selection and approval reject before file reads or transport',
    () async {
      for (final selection in <List<String>>[
        [],
        ['lib/no.dart'],
        ['lib/main.dart', 'lib/main.dart'],
      ]) {
        await controller.request('Tanalyze', selection);
        expect(controller.error, contains('Select'));
      }
      await PlanApprovalStore(records)
          .save(project, ConversationStore(records).load(project.id), false);
      await controller.request('Tanalyze', ['lib/main.dart']);
      expect(reads, 0);
      expect(provider.prompt, isNull);
    },
  );

  test('approval withdrawal during capture prevents inference', () async {
    controller.dispose();
    final capture = Completer<Map<String, String>>();
    controller = create(capture: capture);
    final pending = controller.request('Tanalyze', ['lib/main.dart']);
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), false);
    capture.complete(originals);
    await pending;
    expect(controller.error, contains('failed'));
    expect(provider.prompt, isNull);
    expect(controller.proposal, isNull);
  });

  test('cancel and dispose during capture suppress late inference and notifications', () async {
    for (final dispose in [false, true]) {
      if (!controller.isDisposed) controller.dispose();
      final capture = Completer<Map<String, String>>();
      controller = create(capture: capture);
      var updates = 0;
      controller.addListener(() => updates++);
      final pending = controller.request('Tanalyze', ['lib/main.dart']);
      if (dispose) {
        controller.dispose();
      } else {
        await controller.cancel();
      }
      final before = updates;
      capture.complete(originals);
      await pending;
      expect(provider.prompt, isNull);
      expect(controller.proposal, isNull);
      if (dispose) expect(updates, before);
    }
  });

  test('cancel during inference suppresses completed response', () async {
    final pending = controller.request('Tanalyze', ['lib/main.dart']);
    await tick();
    await controller.cancel();
    provider.stream.add(response());
    await provider.stream.close();
    await pending;
    expect(controller.busy, isFalse);
    expect(controller.proposal, isNull);
    expect(controller.status, contains('cancelled'));
    expect(provider.cancellations, greaterThan(0));
  });

  test('model failure ends busy state and preserves saved outcome', () async {
    final saved = controller.generated;
    final pending = controller.request('Tanalyze', ['lib/main.dart']);
    await tick();
    provider.stream.addError(StateError('offline'));
    await provider.stream.close();
    await pending;
    expect(controller.busy, isFalse);
    expect(controller.error, contains('offline'));
    expect(controller.generated, same(saved));
    expect(controller.proposal, isNull);
  });

  testWidgets(
    'narrow enlarged-text review shows full originals and replacement',
    (tester) async {
      controller.dispose();
      controller = create(
        prepare:
            ({
              required project,
              required generated,
              required evidence,
              required records,
              required parent,
              required checkActive,
            }) async {
              checkActive();
              return GeneratedProject(
                directory: '/candidates/widget',
                sdk: '',
                python: '',
                sources: {},
              );
            },
      );
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SourceReviewScreen(controller: controller),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Tanalyze: analyze'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Tanalyze: analyze'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tanalyze: analyze'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('lib/main.dart'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('lib/main.dart'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('lib/main.dart'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Request source proposal'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Request source proposal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Request source proposal'));
      await tester.pump();
      await tester.pump();
      expect(provider.prompt, isNotNull);
      provider.stream.add(response());
      unawaited(provider.stream.close());
      await tester.pumpAndSettle();
      expect(find.text('Prepare unverified candidate'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Select candidate parent folder'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Select candidate parent folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select candidate parent folder'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Prepare unverified candidate'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Prepare unverified candidate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare unverified candidate'));
      await tester.pumpAndSettle();
      expect(controller.candidate!.directory, '/candidates/widget');
      await tester.scrollUntilVisible(
        find.text('/candidates/widget'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('/candidates/widget'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Line changes'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(controller.proposal!.proposal.changes.single.diff.display),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Original (full file)'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(originals.values.single), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('void main() { print("Hi"); }'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('void main() { print("Hi"); }'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await PlanApprovalStore(records)
          .save(project, ConversationStore(records).load(project.id), false);
      controller.refreshApproval();
      await tester.pumpAndSettle();
      expect(find.text('Line changes'), findsNothing);
      expect(find.text('void main() { print("Hi"); }'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'integrated review shows verified then promoted folder and truthful status',
    (tester) async {
      controller.dispose();
      controller = create(
        prepare:
            ({
              required project,
              required generated,
              required evidence,
              required records,
              required parent,
              required checkActive,
            }) async {
              checkActive();
              return GeneratedProject(
                directory: '/candidates/promoted',
                sdk: '/sdk',
                python: 'python3',
                confined: true,
                sources: GenerationInput(
                  project,
                  ApplicationStore(records).load(project).definition,
                ).fingerprints,
                approval: evidence.approval,
                tasks: BuildPlan.parse(
                  evidence.approval.content,
                  board: RequirementsStore(records).load(project.id),
                ).tasks,
              );
            },
        publish: (value, host, guard) async {
          guard();
          await SourceGenerationStore(records).save(project.id, value);
          return Uri.parse('http://127.0.0.1:1234/promoted/');
        },
      );
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SourceReviewScreen(controller: controller),
        ),
      );
      final request = controller.request('Tanalyze', ['lib/main.dart']);
      await tester.pump();
      await tester.pump();
      provider.stream.add(response());
      unawaited(provider.stream.close());
      await tester.pumpAndSettle();
      await request;
      Future<void> tapText(String text, {double delta = 200}) async {
        await tester.scrollUntilVisible(
          find.text(text),
          delta,
          maxScrolls: 150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.text(text));
        await tester.pumpAndSettle();
        await tester.tap(find.text(text));
        await tester.pumpAndSettle();
      }

      await tapText('Select candidate parent folder');
      await tapText('Prepare unverified candidate');
      expect(controller.error, isNull);
      expect(controller.candidateSession, isNotNull);
      await tapText('I approve confined candidate verification', delta: -200);
      await tapText('Verify candidate in sandbox');
      expect(controller.status, contains('Candidate verified'));
      await tester.scrollUntilVisible(
        find.text('Verified candidate folder (awaiting promotion)'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('Verified candidate folder (awaiting promotion)'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Unverified candidate prepared. Working source and preview retained.',
        ),
        findsNothing,
      );
      await tapText('Promote verified candidate and refresh preview');
      expect(controller.promoted, isTrue);
      expect(controller.status, contains('Candidate promoted'));
      await tester.scrollUntilVisible(
        find.text('Working source folder (promoted candidate)'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('Working source folder (promoted candidate)'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Retained unverified candidate (not saved as working output)',
        ),
        findsNothing,
      );
      expect(
        find.text(
          'Unverified candidate prepared. Working source and preview retained.',
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

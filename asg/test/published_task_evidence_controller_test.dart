// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/published_task_evidence_controller.dart';
import 'package:asg/models/agent_session.dart';
import 'package:asg/models/published_task_evidence.dart';
import 'package:asg/models/prerequisite_preparation_evidence.dart';
import 'package:asg/services/published_task_evidence_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'planning_conversation_test.dart' show project;
import 'agent_task_decision_store_test.dart' show dependentPublication;

import 'package:asg/services/agent_task_decision_store.dart';
import 'package:asg/models/agent_task_decision.dart';

import 'published_task_evidence_store_test.dart' show evidenceFixture;

class ControlledEvidenceStore extends PublishedTaskEvidenceStore {
  ControlledEvidenceStore(RecordStorage records) : super(records, project);
  int calls = 0;
  PublishedTaskEvidence Function()? action;
  @override
  PublishedTaskEvidence load(AgentSession session, int run) {
    calls++;
    return action?.call() ?? super.load(session, run);
  }
}

class ControlledDecisionStore extends AgentTaskDecisionStore {
  ControlledDecisionStore(RecordStorage records) : super(records, project);
  AgentTaskDecision? Function()? action;
  @override
  AgentTaskDecision? load(AgentSession session, int number) =>
      action?.call() ?? super.load(session, number);
}

class ControlledPreparationStore extends AgentPrerequisitePreparationStore {
  ControlledPreparationStore(RecordStorage records)
    : super(records, project.id);
  PrerequisitePreparationReview? Function()? action;
  @override
  PrerequisitePreparationReview? load(AgentSession session, int number) =>
      action == null ? super.load(session, number) : action!();
}

void main() {
  test('preparation-only failure preserves the historical decision, sanitizes errors and retries read-only', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final decisions = AgentTaskDecisionStore(f.records, project);
    final retained = await decisions.confirm(
      decisions.select(f.session, f.run.number),
      consent: true,
      authorized: () => true,
    );
    final preparation = ControlledPreparationStore(f.records)
      ..action = () => throw StateError('private /secret source');
    final c = PublishedTaskEvidenceController(
      PublishedTaskEvidenceStore(f.records, project),
      f.session,
      f.run.number,
      preparation: preparation,
    );
    final before = Map.of(f.records.values);
    c.load();
    expect(c.decision?.fingerprint, retained.fingerprint);
    expect(c.evidence, isNotNull);
    expect(c.preparationReview, isNull);
    expect(c.preparationError, contains('unavailable'));
    expect(c.preparationError, isNot(contains('secret')));
    preparation.action = null;
    c.load();
    expect(c.preparationReview!.prerequisites, isEmpty);
    expect(c.preparationError, isNull);
    expect(f.records.values, before);
    c.dispose();
  });

  test(
    'preparation load suppresses disposal and stale outer reload publication',
    () async {
      final f = await evidenceFixture(
        allAuthoredRules: true,
        taskId: 'Tresolve',
      );
      final decisions = AgentTaskDecisionStore(f.records, project);
      await decisions.confirm(
        decisions.select(f.session, f.run.number),
        consent: true,
        authorized: () => true,
      );
      final preparation = ControlledPreparationStore(f.records);
      final c = PublishedTaskEvidenceController(
        PublishedTaskEvidenceStore(f.records, project),
        f.session,
        f.run.number,
        preparation: preparation,
      );
      var notifications = 0;
      c.addListener(() => notifications++);
      preparation.action = () {
        preparation.action = null;
        c.load();
        return PrerequisitePreparationReview(
          decisionSha256: 'stale',
          runNumber: f.run.number,
          prerequisites: [],
        );
      };
      c.load();
      expect(notifications, 1);
      expect(c.preparationReview!.decisionSha256, c.decision!.fingerprint);
      final other = PublishedTaskEvidenceController(
        PublishedTaskEvidenceStore(f.records, project),
        f.session,
        f.run.number,
        preparation: preparation,
      );
      var disposedNotices = 0;
      other.addListener(() => disposedNotices++);
      preparation.action = () {
        other.dispose();
        return c.preparationReview;
      };
      other.load();
      expect(other.preparationReview, isNull);
      expect(disposedNotices, 0);
      c.dispose();
    },
  );

  test('disposal during retained-history load suppresses late decision and further reads', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final decisions = ControlledDecisionStore(f.records);
    final retained = await decisions.confirm(
      decisions.select(f.session, f.run.number),
      consent: true,
      authorized: () => true,
    );
    final evidence = ControlledEvidenceStore(f.records);
    final c = PublishedTaskEvidenceController(
      evidence,
      f.session,
      f.run.number,
      decisions: decisions,
    );
    var notifications = 0;
    c.addListener(() => notifications++);
    decisions.action = () {
      c.dispose();
      return retained;
    };
    c.load();
    expect(c.decision, isNull);
    expect(evidence.calls, 0);
    expect(notifications, 0);
  });

  test(
    'dependent confirmation requires choosing an exact retained prerequisite',
    () async {
      final first = await evidenceFixture(
        allAuthoredRules: true,
        taskId: 'Tresolve',
      );
      final decisions = AgentTaskDecisionStore(first.records, project);
      await decisions.confirm(
        decisions.select(first.session, first.run.number),
        consent: true,
        authorized: () => true,
      );
      final next = await dependentPublication(first);
      final c = PublishedTaskEvidenceController(
        PublishedTaskEvidenceStore(next.records, project),
        next.session,
        next.run.number,
      )..load();
      expect(c.prerequisiteOptions['Tresolve'], [first.run.number]);
      expect(c.prerequisiteSelection('Tresolve'), isNull);
      c.setConsent(true);
      expect(c.canConfirm, isFalse);
      c.choosePrerequisite('Tresolve', next.run.number);
      expect(c.prerequisiteSelection('Tresolve'), isNull);
      c.choosePrerequisite('Tresolve', first.run.number);
      expect(c.canConsent, isTrue);
      expect(c.consent, isFalse);
      c.setConsent(true);
      expect(await c.confirm(), isTrue);
      expect(
        c.decision!.evidence.prerequisites.single.runNumber,
        first.run.number,
      );
      c.dispose();
    },
  );

  test('explicit consent saves one decision; reload reads retained history without another write', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final c = PublishedTaskEvidenceController(
      PublishedTaskEvidenceStore(f.records, project),
      f.session,
      f.run.number,
    )..load();
    final before = Map.of(f.records.values);
    expect(c.canConsent, isTrue);
    expect(c.canConfirm, isFalse);
    expect(await c.confirm(), isFalse);
    expect(f.records.values, before);
    c.setConsent(true);
    expect(await c.confirm(), isTrue);
    expect(c.decision, isNotNull);
    expect(c.canConfirm, isFalse);
    final saved = Map.of(f.records.values);
    c.load();
    expect(c.decision, isNotNull);
    expect(c.canConsent, isFalse);
    expect(f.records.values, saved);
    c.dispose();
  });

  for (final mode in ['dispose', 'withdraw', 'storage', 'changed']) {
    test(
      'pending confirmation $mode preserves records and suppresses late authority',
      () async {
        final f = await evidenceFixture(
          allAuthoredRules: true,
          taskId: 'Tresolve',
        );
        final c = PublishedTaskEvidenceController(
          PublishedTaskEvidenceStore(f.records, project),
          f.session,
          f.run.number,
        )..load();
        final before = Map.of(f.records.values);
        final gate = Completer<void>();
        f.records.beforeCommit = () => gate.future;
        var notifications = 0;
        c.addListener(() => notifications++);
        c.setConsent(true);
        final pending = c.confirm();
        expect(c.busy, isTrue);
        if (mode == 'dispose') c.dispose();
        if (mode == 'withdraw') c.cancelConfirmation();
        if (mode == 'storage') f.records.failCommit = true;
        if (mode == 'changed') {
          f.records.values['studio.planApproval.v1.${project.id}'] =
              'private changed approval';
        }
        final afterAction = notifications;
        gate.complete();
        expect(await pending, isFalse);
        expect(c.decision, isNull);
        expect(c.canConfirm, isFalse);
        if (mode == 'dispose') {
          expect(notifications, afterAction);
        } else {
          expect(c.decisionError, isNot(contains('private')));
          expect(c.busy, isFalse);
          c.dispose();
        }
        if (mode == 'changed') {
          expect(
            f.records.values,
            Map.of(before)
              ..['studio.planApproval.v1.${project.id}'] =
                  'private changed approval',
          );
        } else {
          expect(f.records.values, before);
        }
      },
    );
  }

  test('reload clears stale projection and sanitizes private errors without changing records', () async {
    final f = await evidenceFixture();
    final store = ControlledEvidenceStore(f.records);
    final c = PublishedTaskEvidenceController(store, f.session, f.run.number);
    final before = Map.of(f.records.values);
    c.load();
    expect(c.evidence, isNotNull);
    expect(c.error, isNull);
    store.action = () =>
        throw StateError('PRIVATE_TOKEN /Users/private-source');
    c.load();
    expect(c.evidence, isNull);
    expect(c.error, contains('unavailable'));
    expect(c.error, isNot(contains('PRIVATE_TOKEN')));
    expect(c.error, isNot(contains('/Users/')));
    expect(f.records.values, before);
    store.action = null;
    c.load();
    expect(c.evidence, isNotNull);
    c.dispose();
  });

  test('disposal before or during a synchronous projection suppresses publication and notifications', () async {
    final f = await evidenceFixture();
    final store = ControlledEvidenceStore(f.records);
    final expected = store.load(f.session, f.run.number);
    var notifications = 0;
    final c = PublishedTaskEvidenceController(store, f.session, f.run.number);
    c.addListener(() => notifications++);
    store.action = () {
      c.dispose();
      return expected;
    };
    c.load();
    expect(c.evidence, isNull);
    expect(notifications, 0);
    final calls = store.calls;
    c.load();
    expect(store.calls, calls);
  });
}

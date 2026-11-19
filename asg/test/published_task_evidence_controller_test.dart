// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/controllers/published_task_evidence_controller.dart';
import 'package:asg/models/agent_session.dart';
import 'package:asg/models/published_task_evidence.dart';
import 'package:asg/services/published_task_evidence_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'planning_conversation_test.dart' show project;
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

void main() {
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

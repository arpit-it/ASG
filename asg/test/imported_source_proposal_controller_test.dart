// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_source_proposal_controller.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/imported_source_proposal_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/record_storage.dart';

import 'imported_plan_test.dart' as fixture;

class ProposalRecords extends fixture.Records
    implements ConditionalRecordStorage {
  Completer<void>? gate;
  final updatesSeen = <Map<String, String>>[];
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    void Function()? authorize,
  }) async {
    updatesSeen.add(Map.of(updates));
    await gate?.future;
    if (expected.entries.any((e) => values[e.key] != e.value)) {
      throw StateError('private durable conflict');
    }
    authorize?.call();
    values.addAll(updates);
  }
}

Future<ProposalRecords> proposalRecords() async {
  final records = ProposalRecords();
  await InspectedFolderStore(records).save('/project');
  records.values[ImportedPlanStore.key('/project')] = jsonEncode(
    ImportedPlan(
      text: 'Review literal replacement',
      context: fixture.capturedSourcePlan().recordJson,
      approved: true,
      recordedAt: DateTime.utc(2026),
    ).toJson(),
  );
  return records;
}

ImportedSourceProposalController proposalController(ProposalRecords records) =>
    ImportedSourceProposalController(
      inspection: fixture.finding(),
      context: fixture.capturedSourcePlan(),
      store: ImportedSourceProposalStore(records),
    );

void main() {
  test(
    'preview binds saved plan and capture without writing any records',
    () async {
      final r = await proposalRecords(),
          before = Map<String, String>.of((await proposalRecords()).values);
      final writes = r.writes;
      final c = proposalController(r);
      await c.load();
      expect(c.canPreview, isTrue);
      await c.preview('lib/main.dart', 'Changed source\r\n');
      expect(c.proposal!.replacement, 'Changed source\r\n');
      expect(c.proposal!.sourceVerified, isFalse);
      expect(c.stale, isFalse);
      expect(r.values, before);
      expect(r.writes, writes);
      expect(r.updatesSeen, everyElement(isEmpty));
      c.dispose();
    },
  );
  test(
    'invalid draft preserves prior comparison and permits corrected retry',
    () async {
      final c = proposalController(await proposalRecords());
      await c.load();
      await c.preview('lib/main.dart', 'First');
      final previous = c.proposal;
      c.invalidateDraft();
      await c.preview('outside.dart', 'private text');
      expect(c.proposal, same(previous));
      expect(c.stale, isTrue);
      expect(c.error, isNot(contains('private text')));
      expect(c.canPreview, isTrue);
      await c.preview('lib/main.dart', 'Second');
      expect(c.proposal, isNot(same(previous)));
      expect(c.stale, isFalse);
      c.dispose();
    },
  );
  test(
    'changed saved plan refuses implicit rebase and requires reload',
    () async {
      final r = await proposalRecords();
      final c = proposalController(r);
      await c.load();
      await c.preview('lib/main.dart', 'First');
      final previous = c.proposal;
      final key = ImportedPlanStore.key('/project');
      r.values[key] = r.values[key]!.replaceFirst(
        'Review literal',
        'Changed literal',
      );
      expect(c.stale, isTrue);
      await c.preview('lib/main.dart', 'Second');
      expect(c.proposal, same(previous));
      expect(c.canPreview, isFalse);
      await c.load();
      await c.preview('lib/main.dart', 'Second');
      expect(c.proposal!.planDigest, isNot(previous!.planDigest));
      c.dispose();
    },
  );
  test(
    'unapproved, missing and corrupt plan fail privately without writes',
    () async {
      for (final value in <String?>[
        null,
        '{}',
        'private corrupt',
        jsonEncode(
          ImportedPlan(
            text: 'Draft',
            context: fixture.capturedSourcePlan().recordJson,
            approved: false,
            recordedAt: DateTime.utc(2026),
          ).toJson(),
        ),
      ]) {
        final r = await proposalRecords();
        final key = ImportedPlanStore.key('/project');
        if (value == null) {
          r.values.remove(key);
        } else {
          r.values[key] = value;
        }
        final c = proposalController(r);
        await c.load();
        expect(c.canPreview, isFalse);
        expect(c.error, isNot(contains('private corrupt')));
        expect(r.updatesSeen, isEmpty);
        c.dispose();
      }
    },
  );
  test(
    'dispose during verification prevents late comparison publication',
    () async {
      final r = await proposalRecords();
      final c = proposalController(r);
      await c.load();
      await c.preview('lib/main.dart', 'First');
      final previous = c.proposal;
      r.gate = Completer<void>();
      final pending = c.preview('lib/main.dart', 'Second');
      expect(c.busy, isTrue);
      c.dispose();
      r.gate!.complete();
      await pending;
      expect(c.proposal, same(previous));
      expect(r.updatesSeen, everyElement(isEmpty));
    },
  );
  test(
    'saved-input change while verification waits retains previous output',
    () async {
      final r = await proposalRecords();
      final c = proposalController(r);
      await c.load();
      await c.preview('lib/main.dart', 'First');
      final previous = c.proposal;
      r.gate = Completer<void>();
      final pending = c.preview('lib/main.dart', 'Second');
      r.values.remove(InspectedFolderStore.key);
      r.gate!.complete();
      await pending;
      expect(c.proposal, same(previous));
      expect(c.stale, isTrue);
      expect(c.canPreview, isFalse);
      c.dispose();
    },
  );
}

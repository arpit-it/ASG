// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_commit_proposal_controller.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/imported_commit_proposal_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/record_storage.dart';

import 'imported_plan_test.dart' as fixture;
import 'imported_commit_proposal_record_test.dart' show capturedCommitPlan;

class ProposalRecords extends fixture.Records
    implements ConditionalRecordStorage {
  Completer<void>? gate, writeGate;
  bool failWrites = false;
  final updatesSeen = <Map<String, String>>[];
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    void Function()? authorize,
  }) async {
    updatesSeen.add(Map.of(updates));
    await gate?.future;
    if (updates.isNotEmpty) await writeGate?.future;
    if (expected.entries.any((e) => values[e.key] != e.value)) {
      throw StateError('private durable conflict');
    }
    authorize?.call();
    if (updates.isNotEmpty && failWrites) {
      throw StateError('private write failure');
    }
    values.addAll(updates);
  }
}

Future<ProposalRecords> proposalRecords() async {
  final records = ProposalRecords();
  await InspectedFolderStore(records).save('/project');
  records.values[ImportedPlanStore.key('/project')] = jsonEncode(
    ImportedPlan(
      text: 'Review literal replacement',
      context: capturedCommitPlan().recordJson,
      approved: true,
      recordedAt: DateTime.utc(2026),
    ).toJson(),
  );
  return records;
}

ImportedCommitProposalController proposalController(ProposalRecords records) =>
    ImportedCommitProposalController(
      inspection: fixture.finding(),
      context: capturedCommitPlan(),
      store: ImportedCommitProposalStore(records),
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
            context: capturedCommitPlan().recordJson,
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
        expect(r.updatesSeen, everyElement(isEmpty));
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
  test('explicit save is durable before success; history-only reload needs no plan or source capture', () async {
    final r = await proposalRecords(),
        c = proposalController(await proposalRecords());
    c.dispose();
    final owner = proposalController(r);
    await owner.load();
    await owner.preview('lib/main.dart', 'Saved replacement');
    await owner.save(owner.proposal!);
    final raw = r.values[ImportedCommitProposalStore.key('/project')];
    expect(raw, isNotNull);
    expect(owner.saved!.encode(), raw);
    expect(owner.canSave, isFalse);
    r.values.remove(ImportedPlanStore.key('/project'));
    final history = ImportedCommitProposalController.history(
      root: '/project',
      store: ImportedCommitProposalStore(r),
    );
    await history.load();
    expect(history.saved!.proposal.replacement, 'Saved replacement');
    expect(history.context, isNull);
    expect(history.plan, isNull);
    expect(history.proposal, isNull);
    expect(history.canPreview, isFalse);
    expect(history.canSave, isFalse);
    expect(r.values[ImportedCommitProposalStore.key('/project')], raw);
    owner.dispose();
    history.dispose();
  });
  test('failed save retains last saved bytes and draft comparison; unchanged retry succeeds', () async {
    final r = await proposalRecords();
    final c = proposalController(r);
    await c.load();
    await c.preview('lib/main.dart', 'First');
    await c.save(c.proposal!);
    final before = c.saved!.encode();
    await c.preview('lib/main.dart', 'Second');
    final draft = c.proposal;
    r.failWrites = true;
    await c.save(draft!);
    expect(c.saved!.encode(), before);
    expect(r.values[ImportedCommitProposalStore.key('/project')], before);
    expect(c.proposal, same(draft));
    expect(c.canSave, isTrue);
    expect(c.error, isNot(contains('private write failure')));
    r.failWrites = false;
    await c.save(draft);
    expect(c.saved!.proposal.replacement, 'Second');
    expect(c.error, isNull);
    c.dispose();
  });
  test(
    'dispose while save waits prevents late transaction authorization',
    () async {
      final r = await proposalRecords();
      final c = proposalController(r);
      await c.load();
      await c.preview('lib/main.dart', 'First');
      await c.save(c.proposal!);
      final before = c.saved!.encode();
      await c.preview('lib/main.dart', 'Second');
      r.writeGate = Completer<void>();
      final pending = c.save(c.proposal!);
      expect(c.busy, isTrue);
      expect(c.saved!.encode(), before);
      c.dispose();
      r.writeGate!.complete();
      await pending;
      expect(r.values[ImportedCommitProposalStore.key('/project')], before);
    },
  );
  test(
    'changed previous record during save preserves external winner',
    () async {
      final r = await proposalRecords();
      final c = proposalController(r);
      await c.load();
      await c.preview('lib/main.dart', 'First');
      await c.save(c.proposal!);
      final key = ImportedCommitProposalStore.key('/project');
      final data = jsonDecode(c.saved!.encode()) as Map<String, dynamic>;
      data['recordedAt'] = DateTime.utc(2027).toIso8601String();
      final winner = jsonEncode(data);
      await c.preview('lib/main.dart', 'Second');
      r.writeGate = Completer<void>();
      final pending = c.save(c.proposal!);
      r.values[key] = winner;
      r.writeGate!.complete();
      await pending;
      expect(r.values[key], winner);
      expect(c.stale, isTrue);
      expect(c.canSave, isFalse);
      expect(c.proposal!.replacement, 'Second');
      c.dispose();
    },
  );
  test(
    'draft invalidation and corrupt saved history cannot silently overwrite',
    () async {
      final r = await proposalRecords();
      final c = proposalController(r);
      await c.load();
      await c.preview('lib/main.dart', 'First');
      final p = c.proposal!;
      c.invalidateDraft();
      await c.save(p);
      expect(c.saved, isNull);
      expect(r.updatesSeen, everyElement(isEmpty));
      final key = ImportedCommitProposalStore.key('/project');
      r.values[key] = 'private corrupt history';
      await c.load();
      expect(c.historyError, isNotNull);
      expect(c.canPreview, isFalse);
      expect(r.values[key], 'private corrupt history');
      expect(c.historyError, isNot(contains('private corrupt history')));
      c.dispose();
    },
  );
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/models/build_plan.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/plan_approval.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/studio_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'board_mapped_build_plan_test.dart' show boardContent, mappedBoard;
import 'planning_conversation_test.dart' show ControlledRecords, project, tick;
import 'source_edit_proposer_test.dart' show FakeProvider;

const originals = {'lib/main.dart': 'void main() {}'};
String response() => jsonEncode({
  'summary': 'Greeting',
  'changes': [
    {
      'path': 'lib/main.dart',
      'before': originals.values.single,
      'after': 'void main() { print("Hi"); }',
    },
  ],
});
Future<void> seed(
  ControlledRecords records, {
  bool approved = true,
  String? content,
}) async {
  await StudioStore(records).save([project]);
  final store = RequirementsStore(records);
  await store.save(project.id, store.load(project.id), mappedBoard());
  final approvals = PlanApprovalStore(records);
  final messages = [
    ChatMessage(
      role: 'assistant',
      content: content ?? boardContent(),
      planContext: approvals.contextFor(project),
    ),
  ];
  await ConversationStore(records).save(project.id, messages);
  await approvals.save(project, messages, approved);
}

ApprovedSourceProposer serviceFor(
  ControlledRecords records,
  FakeProvider provider,
) => ApprovedSourceProposer(
  records,
  proposer: SourceEditProposer(createProvider: (_) => provider),
);

void main() {
  test(
    'saved task and acceptance bind review evidence without writes',
    () async {
      final records = ControlledRecords();
      await seed(records);
      final provider = FakeProvider();
      final service = serviceFor(records, provider);
      final writes = records.writes;
      final pending = service.propose(
        project: project,
        boardTaskId: 'Tanalyze',
        config: const LocalModelConfig(),
        originals: originals,
      );
      expect(provider.prompt, contains('Verify output'));
      expect(provider.prompt, contains('Tanalyze'));
      provider.stream.add(response());
      await provider.stream.close();
      final evidence = await pending;
      expect(evidence.modelRequest!.model, 'Qwen3.5-9B');
      expect(evidence.modelRequest!.outputTokens, 4096);
      expect(evidence.boardTaskId, 'Tanalyze');
      expect(evidence.projectId, project.id);
      expect(
        evidence.approval.matches(PlanApprovalStore(records).load(project.id)!),
        isTrue,
      );
      expect(evidence.proposal.changes.single.before, originals.values.single);
      service.requireCurrent(project, evidence);
      expect(records.writes, writes);
      await PlanApprovalStore(records)
          .save(project, ConversationStore(records).load(project.id), false);
      expect(() => service.requireCurrent(project, evidence), throwsStateError);
    },
  );
  test('invalid approval or unmapped task fails before transport', () async {
    for (final kind in [
      'missing',
      'withdrawn',
      'stale',
      'unknown',
      'unmapped',
      'invalid',
    ]) {
      final records = ControlledRecords();
      if (kind != 'missing') {
        await seed(
          records,
          approved: kind != 'withdrawn',
          content: kind == 'unmapped'
              ? BuildPlan.starterContract
              : kind == 'invalid'
              ? 'advisory'
              : null,
        );
      }
      if (kind == 'stale') {
        final store = RequirementsStore(records);
        await store.save(project.id, store.load(project.id), mappedBoard());
      }
      var calls = 0;
      final service = ApprovedSourceProposer(
        records,
        proposer: SourceEditProposer(
          createProvider: (_) {
            calls++;
            return FakeProvider();
          },
        ),
      );
      await expectLater(
        service.propose(
          project: project,
          boardTaskId: kind == 'unknown' ? 'absent' : 'Tanalyze',
          config: const LocalModelConfig(),
          originals: originals,
        ),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(calls, 0, reason: kind);
    }
  });
  test(
    'changes during inference or cleanup reject late evidence and permit retry',
    () async {
      for (final kind in ['withdraw', 'reapprove', 'requirements', 'cleanup']) {
        final records = ControlledRecords();
        await seed(records);
        final first = FakeProvider(), second = FakeProvider();
        var calls = 0;
        final service = ApprovedSourceProposer(
          records,
          proposer: SourceEditProposer(
            createProvider: (_) => calls++ == 0 ? first : second,
          ),
        );
        final pending = service.propose(
          project: project,
          boardTaskId: 'Tanalyze',
          config: const LocalModelConfig(),
          originals: originals,
        );
        final rejected = expectLater(pending, throwsStateError);
        if (kind == 'cleanup') {
          first.cleanup = Completer<void>();
          first.stream.add(response());
          await first.stream.close();
          await tick();
        }
        final approvals = PlanApprovalStore(records);
        if (kind == 'requirements') {
          final store = RequirementsStore(records);
          await store.save(project.id, store.load(project.id), mappedBoard());
        } else if (kind == 'reapprove') {
          final old = approvals.load(project.id)!;
          await records.setString(
            'studio.planApproval.v1.${project.id}',
            jsonEncode(
              PlanApproval(
                messageIndex: old.messageIndex,
                content: old.content,
                context: old.context,
                approved: true,
                recordedAt: old.recordedAt.add(const Duration(seconds: 1)),
              ).toJson(),
            ),
          );
        } else {
          await approvals.save(
            project,
            ConversationStore(records).load(project.id),
            false,
          );
        }
        if (kind == 'cleanup') {
          first.cleanup!.complete();
        } else {
          first.stream.add(response());
          await first.stream.close();
        }
        await rejected;
        await seed(records);
        final retry = service.propose(
          project: project,
          boardTaskId: 'Tanalyze',
          config: const LocalModelConfig(),
          originals: originals,
        );
        second.stream.add(response());
        await second.stream.close();
        expect((await retry).proposal.summary, 'Greeting');
      }
    },
  );
  test(
    'concurrent request rejects; cancel during cleanup prevents publication',
    () async {
      final records = ControlledRecords();
      await seed(records);
      final provider = FakeProvider()..cleanup = Completer<void>();
      var calls = 0;
      final service = ApprovedSourceProposer(
        records,
        proposer: SourceEditProposer(
          createProvider: (_) {
            calls++;
            return provider;
          },
        ),
      );
      final pending = service.propose(
        project: project,
        boardTaskId: 'Tanalyze',
        config: const LocalModelConfig(),
        originals: originals,
      );
      final rejected = expectLater(pending, throwsStateError);
      await expectLater(
        service.propose(
          project: project,
          boardTaskId: 'Tanalyze',
          config: const LocalModelConfig(),
          originals: originals,
        ),
        throwsStateError,
      );
      provider.stream.add(response());
      await provider.stream.close();
      await tick();
      final cancelled = service.cancel();
      provider.cleanup!.complete();
      await cancelled;
      await rejected;
      expect(calls, 1);
    },
  );
}

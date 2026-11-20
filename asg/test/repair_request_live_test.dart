// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/selected_repair_request.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/services/selected_repair_request_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'approved_source_proposer_test.dart' show originals, response;
import 'initial_request_live_readiness.dart';
import 'live_model_config.dart' show liveModelId;
import 'planning_conversation_test.dart' show project;
import 'candidate_reopen_context_test.dart' show reopenFixture;
import 'candidate_repair_proposer_test.dart' show boundFailure, saveFailure;

/// Verifies physical atomic origin+journal before transport can begin.
class _IntentObserver implements ConditionalRecordStorage {
  _IntentObserver(this.records, this.database, this.key, this.originKey);
  final StudioDatabase records;
  final Database database;
  final String key, originKey;
  int reservations = 0;
  @override
  String? getString(String key) => records.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      records.setString(key, value);
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    await records.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
    if (updates.containsKey(key)) {
      final physical = await StoreRef<String, String>('records')
          .record(key)
          .get(database);
      expect(physical, updates[key]);
      final entry = RepairAttemptJournal.fromJson(
        jsonDecode(physical!) as Map<String, dynamic>,
      ).attempts.single;
      final raw = await StoreRef<String, String>('records')
          .record(originKey)
          .get(database);
      final origin = SelectedRepairRequest.decode(raw!);
      origin.requireAttempt(entry);
      if (entry.status == RepairAttemptStatus.reserved) {
        reservations++;
        expect(updates.keys.toSet(), {key, originKey});
        expect(raw, updates[originKey]);
        expect(entry.modelRequest!.responseModel, isNull);
      }
    }
  }
}

/// Same assertions for synthetic HTTP and one opt-in fixed-owner repair request.
/// Returned source stays private/in memory and is never applied or executed.
Future<void> _verifyJournal({
  required LocalModelConfig config,
  required Future<void> Function() preflight,
}) async {
  await preflight(); // Before fixture storage or proposer effects.
  Directory? root;
  Database? database;
  ApprovedSourceProposer? service;
  Future<void>? settled;
  try {
    final seed = await reopenFixture();
    final failed = GeneratedProject.fromJson({
      ...seed.basis.sourceBase
          .copy(
            phase: SourceGenerationPhase.failed,
            checkpointVersion: 1,
            steps: boundFailure(seed.records).steps,
            outputs: {},
          )
          .toJson(),
      'directory': '/supplied-failed-candidate',
    });
    await saveFailure(seed.records, failed);
    final binding = AgentSessionBinding.select(
      session: seed.session,
      projectId: project.id,
      boardTaskId: 'Tanalyze',
    );
    root = await Directory.systemTemp.createTemp('asg-repair-live-journal-');
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    final records = await StudioDatabase.migrate(database, preferences);
    for (final e in seed.records.values.entries) {
      await records.setString(e.key, e.value);
    }
    Future<Map<String, String>> raw(Database db) async => {
      for (final row in await StoreRef<String, String>('records').find(db))
        row.key: row.value,
    };
    final before = await raw(database),
        key = 'studio.repairAttempts.v1.${project.id}',
        originKey = '${SelectedRepairRequest.prefix}${project.id}.1';
    final observer = _IntentObserver(records, database, key, originKey);
    service = ApprovedSourceProposer(
      observer,
    ); // Default production HTTP transport.
    final pending = service.propose(
      project: project,
      boardTaskId: 'Tanalyze',
      config: config,
      originals: originals,
      repairCandidate: failed,
      repairSessionBinding: binding,
      repairWorkingRecord: records.getString(
        'studio.generation.v1.${project.id}',
      ),
    );
    settled = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    final ApprovedSourceProposal evidence = await pending.timeout(
      const Duration(minutes: 2),
    );
    expect(observer.reservations, 1);
    expect(evidence.modelRequest!.responseModel, config.model);
    final journalRaw = records.getString(key)!,
        originRaw = records.getString(originKey)!;
    final origin = SelectedRepairRequest.decode(originRaw);
    final entry = RepairAttemptStore(
      records,
      project.id,
    ).load().attempts.single;
    expect(entry.status, RepairAttemptStatus.proposed);
    expect(entry.modelRequest!.model, config.model);
    expect(entry.modelRequest!.responseModel, config.model);
    expect(entry.modelRequest!.outputTokens, 4096);
    expect(origin.requestSessionRecord, before[binding.session.storageKey]);
    evidence.repairRequestReference!.requireMatch(origin, entry);
    expect(entry.proposal!.summary, evidence.proposal.summary);
    expect(
      entry.proposal!.changes.map((c) => (c.path, c.before, c.after)).toList(),
      evidence.proposal.changes
          .map((c) => (c.path, c.before, c.after))
          .toList(),
    );
    final after = await raw(database);
    expect(after, {...before, key: journalRaw, originKey: originRaw});
    await service.cancel();
    await settled;
    await database.close();
    database = null;
    database = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    final reopened = await StudioDatabase.migrate(database, preferences);
    expect(await raw(database), after);
    final page = SelectedRepairRequestStore(
      reopened,
      project.id,
    ).load(binding.session.sessionId);
    expect(page.entries.single.origin!.encode(), originRaw);
    page.entries.single.reference!.requireMatch(
      origin,
      RepairAttemptStore(reopened, project.id).load().attempts.single,
    );
  } finally {
    try {
      await service?.cancel();
    } finally {
      try {
        await settled?.timeout(const Duration(seconds: 10));
      } finally {
        try {
          await database?.close();
        } finally {
          await root?.delete(recursive: true);
        }
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('same selected-repair native harness passes synthetic HTTP, not live inference', () async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    HttpServer? server;
    StreamSubscription<HttpRequest>? subscription;
    final handled = Completer<void>();
    Object? failure;
    StackTrace? failureStack;
    var calls = 0;
    const model = 'synthetic-selected-repair-live-harness';
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      subscription = server.listen((request) async {
        calls++;
        try {
          expect(request.method, 'POST');
          expect(request.uri.path, '/v1/chat/completions');
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(body['model'], model);
          expect(body['stream'], true);
          expect(body['max_tokens'], 4096);
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(
            'data: ${jsonEncode({
              'model': model,
              'choices': [
                {
                  'delta': {'content': response()},
                },
              ],
            })}\n\n',
          );
          request.response.write(
            'data: ${jsonEncode({
              'model': model,
              'choices': [
                {'delta': {}, 'finish_reason': 'stop'},
              ],
            })}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        } catch (error, stack) {
          failure = error;
          failureStack = stack;
          try {
            await request.response.close();
          } catch (_) {
            // Preserve original callback failure after an already closed response.
          }
        } finally {
          if (!handled.isCompleted) handled.complete();
        }
      });
      await _verifyJournal(
        config: LocalModelConfig(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: model,
        ),
        preflight:
            () async {}, // Supplied fixture; never labelled live readiness.
      );
      await handled.future.timeout(const Duration(seconds: 5));
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      expect(calls, 1, reason: 'Native reopen must not replay generation.');
      await expectLater(
        _verifyJournal(
          config: LocalModelConfig(
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: model,
          ),
          preflight: () async =>
              throw StateError('Supplied readiness refusal.'),
        ),
        throwsStateError,
      );
      expect(calls, 1, reason: 'Failed readiness must not generate or retry.');
    } finally {
      try {
        await server?.close(force: true);
        await subscription?.cancel();
        if (calls != 0) {
          await handled.future.timeout(const Duration(seconds: 5));
        }
      } finally {
        HttpOverrides.global = previous;
      }
    }
  });
  test(
    'owner Qwen selected repair retains exact response identity across native reopen',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        await _verifyJournal(
          config: const LocalModelConfig(
            baseUrl: 'http://127.0.0.1:8765/v1',
            model: liveModelId,
          ),
          preflight: checkSourceRequestLiveReadiness,
        );
      } finally {
        HttpOverrides.global = previous;
      }
    },
    skip: !const bool.fromEnvironment('ASG_REAL_INFERENCE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

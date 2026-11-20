// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/session_proposal_request.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/session_proposal_request_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'approved_source_proposer_test.dart'
    show initialContext, originals, response;
import 'initial_request_live_readiness.dart';
import 'live_model_config.dart' show liveModelId;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

/// Checks the actual native reservation before its completion permits transport.
class _IntentObserver implements ConditionalRecordStorage {
  _IntentObserver(this.records, this.database, this.key);
  final StudioDatabase records;
  final Database database;
  final String key;
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
      final entry = SessionProposalRequestJournal.decode(physical!)
          .requests
          .single;
      if (entry.status == SessionProposalRequestStatus.reserved) {
        reservations++;
        expect(entry.modelRequest.responseModel, isNull);
      }
    }
  }
}

/// Same bounded journal assertions for a supplied HTTP fixture and opt-in runtime.
/// Returned source is inspected in memory only; no candidate or command is created.
Future<void> _verifyJournal({
  required LocalModelConfig config,
  required Future<void> Function() preflight,
}) async {
  // A failed readiness check must precede all storage/proposer effects.
  await preflight();
  Directory? root;
  Database? database;
  ApprovedSourceProposer? service;
  Future<void>? settled;
  try {
    final seed = AtomicRecords();
    final selected = await initialContext(seed);
    root = await Directory.systemTemp.createTemp('asg-initial-live-journal-');
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    final records = await StudioDatabase.migrate(database, preferences);
    for (final entry in seed.values.entries) {
      await records.setString(entry.key, entry.value);
    }
    Future<Map<String, String>> raw(Database db) async => {
      for (final row in await StoreRef<String, String>('records').find(db))
        row.key: row.value,
    };
    final before = await raw(database);
    final key =
        '${SessionProposalRequestStore.prefix}${project.id}.${selected.binding.session.sessionId}';
    final observer = _IntentObserver(records, database, key);
    service = ApprovedSourceProposer(
      observer,
    ); // Default production HTTP transport.
    final pending = service.propose(
      project: project,
      boardTaskId: 'Tanalyze',
      config: config,
      originals: originals,
      sessionBinding: selected.binding,
      requestWorkingRecord: selected.working,
      authorizeSession: () {},
    );
    settled = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    final ApprovedSourceProposal evidence = await pending.timeout(
      const Duration(minutes: 2),
    );
    expect(observer.reservations, 1);
    expect(evidence.modelRequest!.responseModel, config.model);
    final origin = evidence.initialRequestOrigin!;
    expect(origin.reference.number, 1);
    expect(
      origin.requestSessionRecord,
      before[selected.binding.session.storageKey],
    );
    final journalRaw = records.getString(key)!;
    final entry = SessionProposalRequestJournal.decode(journalRaw)
        .requests
        .single;
    expect(entry.status, SessionProposalRequestStatus.returnedValidated);
    expect(entry.modelRequest.model, config.model);
    expect(entry.modelRequest.responseModel, config.model);
    expect(origin.reference.matches(entry), isTrue);
    expect(
      entry.sessionSha256,
      SessionProposalRequestStore.fingerprint(origin.requestSessionRecord),
    );
    expect(entry.returnedSha256, {
      for (final change in evidence.proposal.changes)
        change.path: SessionProposalRequestStore.fingerprint(change.after),
    });
    final after = await raw(database);
    expect(after, {...before, key: journalRaw});
    expect(
      records.getString('studio.candidateChecks.v1.${project.id}'),
      isNull,
    );
    for (final change in evidence.proposal.changes) {
      expect(jsonDecode(journalRaw).toString().contains(change.after), isFalse);
    }
    await service.cancel();
    await settled;
    await database.close();
    database = null;
    database = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    final reopened = await StudioDatabase.migrate(database, preferences);
    expect(reopened.getString(key), journalRaw);
    expect(await raw(database), after);
    expect(
      SessionProposalRequestStore(
        reopened,
        project.id,
        selected.binding.session.sessionId,
      ).load().requests.single.toJson(),
      entry.toJson(),
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
  test('same native journal harness passes supplied HTTP metadata, not live inference', () async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    HttpServer? server;
    StreamSubscription<HttpRequest>? subscription;
    final handled = Completer<void>();
    Object? failure;
    StackTrace? failureStack;
    var calls = 0;
    const model = 'synthetic-initial-live-harness';
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
          await request.response.close();
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
      } finally {
        HttpOverrides.global = previous;
      }
    }
  });
  test(
    'owner Qwen initial request retains exact response identity across native reopen',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        await _verifyJournal(
          config: const LocalModelConfig(
            baseUrl: 'http://127.0.0.1:8765/v1',
            model: liveModelId,
          ),
          preflight: checkInitialRequestLiveReadiness,
        );
      } finally {
        HttpOverrides.global = previous;
      }
    },
    skip: !const bool.fromEnvironment('ASG_REAL_INFERENCE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

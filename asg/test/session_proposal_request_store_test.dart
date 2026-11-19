// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/session_proposal_request.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/session_proposal_request_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'approved_source_proposer_test.dart' show seed, originals, response;
import 'agent_session_store_test.dart' show selection;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

const model = ModelRequestProvenance(
  model: 'Qwen3.8-27B-4bit',
  outputTokens: 4096,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AtomicRecords records;
  late AgentSessionBinding binding;
  late SessionProposalRequestStore store;
  late String working;
  const workingKey = 'studio.generation.v1.planning';
  setUp(() async {
    records = AtomicRecords();
    await seed(records);
    final session = await AgentSessionStore(
      records,
      project,
    ).create('initial', selection(records));
    binding = AgentSessionBinding.select(
      session: session,
      projectId: project.id,
      boardTaskId: 'Tanalyze',
    );
    working = jsonEncode(
      GeneratedProject(
        directory: '/working',
        sdk: '/sdk',
        python: 'python3',
        sources: {
          for (final e in originals.entries)
            e.key: SessionProposalRequestStore.fingerprint(e.value),
        },
      ).toJson(),
    );
    await records.setString(workingKey, working);
    store = SessionProposalRequestStore(records, project.id, 'initial');
  });
  Future<SessionProposalRequest> reserve({
    Map<String, String>? source,
    void Function()? authorize,
  }) => store.reserve(
    project: project,
    binding: binding,
    workingRecord: working,
    originals: source ?? originals,
    modelRequest: model,
    authorize: authorize ?? () {},
  );
  test(
    'reservation precedes any transport and touches only exact history key',
    () async {
      final before = Map.of(records.values);
      final request = await reserve();
      expect(request.status, SessionProposalRequestStatus.reserved);
      expect(
        request.workingSha256,
        SessionProposalRequestStore.fingerprint(working),
      );
      expect(
        request.sourceSha256['lib/main.dart'],
        SessionProposalRequestStore.fingerprint(originals.values.single),
      );
      expect(
        request.sessionSha256,
        SessionProposalRequestStore.fingerprint(
          before[binding.session.storageKey]!,
        ),
      );
      expect(store.load().requests.single.toJson(), request.toJson());
      final reopened = SessionProposalRequestStore(
        records,
        project.id,
        'initial',
      );
      final retained = Map.of(records.values);
      expect(
        reopened.load().requests.single.status,
        SessionProposalRequestStatus.reserved,
      );
      expect(records.values, retained);
      expect(Map.of(records.values)..remove(store.key), before);
    },
  );
  test('reservation failures preserve every record', () async {
    for (final kind in [
      'commit',
      'cancel',
      'source',
      'working',
      'session',
      'approval',
    ]) {
      records.failCommit = kind == 'commit';
      final before = Map.of(records.values);
      if (kind == 'working') {
        records.beforeCommit = () async {
          records.values[workingKey] = '$working ';
        };
      }
      if (kind == 'session') {
        records.beforeCommit = () async {
          records.values[binding.session.storageKey] =
              '${before[binding.session.storageKey]} ';
        };
      }
      if (kind == 'approval') {
        records.beforeCommit = () async {
          records.values['studio.planApproval.v1.planning'] = '{}';
        };
      }
      await expectLater(
        reserve(
          source: kind == 'source' ? {'lib/main.dart': 'different'} : null,
          authorize: kind == 'cancel'
              ? () {
                  throw StateError('cancelled');
                }
              : null,
        ),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(records.values.containsKey(store.key), isFalse, reason: kind);
      records.values
        ..clear()
        ..addAll(before);
      records.beforeCommit = null;
      records.failCommit = false;
    }
  });
  test('terminal history stores fingerprints only and permits next explicit reservation', () async {
    await reserve();
    final proposal = SourceEditProposal.parse(
      jsonDecode(response()),
      originals: originals,
    );
    var authorized = 0;
    await store.finish(
      SessionProposalRequestStatus.returnedValidated,
      proposal: proposal,
      authorizeReturn: () {
        authorized++;
      },
    );
    expect(authorized, 1);
    final value = store.load().requests.single;
    expect(store.returnedOrigin, isNotNull);
    store.returnedOrigin!.requireRequest(value);
    expect(
      store.referenced(store.returnedOrigin!.reference).toJson(),
      value.toJson(),
    );
    expect(value.status, SessionProposalRequestStatus.returnedValidated);
    expect(
      value.returnedSha256.values.single,
      SessionProposalRequestStore.fingerprint(proposal.changes.single.after),
    );
    expect(records.values[store.key], isNot(contains('print(')));
    await reserve();
    await store.finish(SessionProposalRequestStatus.failedLocally);
    expect(store.load().requests.map((r) => r.number), [1, 2]);
  });
  test('outcome persistence failure leaves unresolved intent without fallback rewrite', () async {
    await reserve();
    final reserved = records.values[store.key];
    records.failCommit = true;
    await expectLater(
      store.finish(SessionProposalRequestStatus.failedLocally),
      throwsStateError,
    );
    records.failCommit = false;
    await expectLater(
      store.finish(SessionProposalRequestStatus.cancelledLocally),
      throwsStateError,
    );
    expect(records.values[store.key], reserved);
    expect(store.returnedOrigin, isNull);
    expect(
      SessionProposalRequestStore(
        records,
        project.id,
        'initial',
      ).load().requests.single.status,
      SessionProposalRequestStatus.reserved,
    );
  });
  test('changed owned reservation and return authorization cannot publish false outcome', () async {
    await reserve();
    final before = records.values[store.key]!;
    records.values[store.key] = before.replaceFirst(
      '"boardTaskId":"Tanalyze"',
      '"boardTaskId":"Ttest"',
    );
    await expectLater(
      store.finish(SessionProposalRequestStatus.failedLocally),
      throwsStateError,
    );
    records.values[store.key] = before;
    final proposal = SourceEditProposal.parse(
      jsonDecode(response()),
      originals: originals,
    );
    await expectLater(
      store.finish(
        SessionProposalRequestStatus.returnedValidated,
        proposal: proposal,
        authorizeReturn: () {
          throw StateError('withdrawn');
        },
      ),
      throwsStateError,
    );
    expect(records.values[store.key], before);
  });
  test('local cancellation can be recorded after session withdrawal without changing session', () async {
    await reserve();
    await AgentSessionStore(
      records,
      project,
    ).requestCancellation(binding.session);
    final withdrawn = Map.of(records.values);
    await store.finish(SessionProposalRequestStatus.cancelledLocally);
    expect(
      store.load().requests.single.status,
      SessionProposalRequestStatus.cancelledLocally,
    );
    expect(
      Map.of(records.values)..remove(store.key),
      Map.of(withdrawn)..remove(store.key),
    );
  });
  test('corrupt, foreign and full histories fail before reservation', () async {
    final request = await reserve();
    for (final raw in [
      '{}',
      SessionProposalRequestJournal([request])
          .encode()
          .replaceAll('"sessionId":"initial"', '"sessionId":"other"'),
      SessionProposalRequestJournal([
        for (var i = 1; i <= 32; i++)
          SessionProposalRequest.fromJson({...request.toJson(), 'number': i}),
      ]).encode(),
    ]) {
      records.values[store.key] = raw;
      final fresh = SessionProposalRequestStore(records, project.id, 'initial');
      await expectLater(
        fresh.reserve(
          project: project,
          binding: binding,
          workingRecord: working,
          originals: originals,
          modelRequest: model,
          authorize: () {},
        ),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(records.values[store.key], raw);
    }
  });
  test(
    'two concurrent reservations cannot append the same intent twice',
    () async {
      final gate = Completer<void>();
      var entered = 0;
      records.beforeCommit = () async {
        entered++;
        if (entered == 2) gate.complete();
        await gate.future;
      };
      final second = SessionProposalRequestStore(
        records,
        project.id,
        'initial',
      );
      final outcomes = await Future.wait([
        reserve().then((_) => true, onError: (_) => false),
        second
            .reserve(
              project: project,
              binding: binding,
              workingRecord: working,
              originals: originals,
              modelRequest: model,
              authorize: () {},
            )
            .then((_) => true, onError: (_) => false),
      ]);
      expect(outcomes.where((value) => value), hasLength(1));
      expect(store.load().requests, hasLength(1));
      expect(store.load().requests.single.number, 1);
      records.beforeCommit = null;
    },
  );

  test('actual native database reopen retains unresolved metadata with no replay or writes', () async {
    final root = await Directory.systemTemp.createTemp('asg-initial-request-');
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      var native = await StudioDatabase.migrate(db, preferences);
      for (final e in records.values.entries) {
        await native.setString(e.key, e.value);
      }
      var nativeStore = SessionProposalRequestStore(
        native,
        project.id,
        'initial',
      );
      await nativeStore.reserve(
        project: project,
        binding: binding,
        workingRecord: working,
        originals: originals,
        modelRequest: model,
        authorize: () {},
      );
      final raw = native.getString(nativeStore.key);
      // A separately committed session update is invisible to this adapter's
      // cache. Returning a proposal still needs durable session/context CAS.
      final cachedSession = native.getString(binding.session.storageKey);
      await StoreRef<String, String>('records')
          .record(binding.session.storageKey)
          .put(db, jsonEncode(binding.session.requestCancellation().toJson()));
      expect(native.getString(binding.session.storageKey), cachedSession);
      await expectLater(
        nativeStore.finish(
          SessionProposalRequestStatus.returnedValidated,
          proposal: SourceEditProposal.parse(
            jsonDecode(response()),
            originals: originals,
          ),
          authorizeReturn: () {},
        ),
        throwsStateError,
      );
      expect(native.getString(nativeStore.key), raw);
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      native = await StudioDatabase.migrate(db, preferences);
      nativeStore = SessionProposalRequestStore(native, project.id, 'initial');
      expect(
        nativeStore.load().requests.single.status,
        SessionProposalRequestStatus.reserved,
      );
      expect(native.getString(nativeStore.key), raw);
      expect(native.getString(workingKey), working);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}

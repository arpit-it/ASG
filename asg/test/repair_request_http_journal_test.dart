// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/local_model_config.dart';
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
import 'planning_conversation_test.dart' show project;
import 'candidate_reopen_context_test.dart' show reopenFixture;
import 'candidate_repair_proposer_test.dart' show boundFailure, saveFailure;

const _model = 'synthetic-http-repair-metadata';
const _wait = Duration(seconds: 10);

enum _AmbiguousMetadata { plain, escaped, terminalPlain, terminalEscaped }

/// Actual native commit, with its completion withheld before transport may start.
class _ReservationBoundary implements ConditionalRecordStorage {
  _ReservationBoundary(this.delegate, {required this.refuse});
  final ConditionalRecordStorage delegate;
  final bool refuse;
  final entered = Completer<void>(), release = Completer<void>();
  bool _seen = false;

  @override
  String? getString(String key) => delegate.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      delegate.setString(key, value);
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    final reserve =
        !_seen &&
        updates.keys.any((key) => key.startsWith('studio.repairAttempts.v1.'));
    if (reserve) {
      _seen = true;
      if (updates.length != 2 ||
          !updates.keys.any(
            (k) => k.startsWith(SelectedRepairRequest.prefix),
          )) {
        throw StateError('Atomic repair origin and journal required.');
      }
      if (refuse) throw StateError('Supplied reservation persistence refusal.');
    }
    await delegate.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
    if (reserve) {
      entered.complete();
      await release.future;
    }
  }

  void releaseIfHeld() {
    if (!release.isCompleted) release.complete();
  }
}

class _Fixture {
  _Fixture(
    this.root,
    this.preferences,
    this.database,
    this.records,
    this.server,
    this.binding,
    this.working,
    this.failed,
  );
  final Directory root;
  final SharedPreferences preferences;
  Database? database;
  StudioDatabase records;
  final HttpServer server;
  final AgentSessionBinding binding;
  final String working;
  final GeneratedProject failed;
  ApprovedSourceProposer? service;
  Future<void>? _settled;
  _ReservationBoundary? boundary;
  StreamSubscription<HttpRequest>? subscription;
  final handled = Completer<void>();
  Object? callbackError;
  StackTrace? callbackStack;
  int httpCalls = 0, validPartialFramesFlushed = 0;

  String get journalKey => 'studio.repairAttempts.v1.${project.id}';
  String get originKey => '${SelectedRepairRequest.prefix}${project.id}.1';
  LocalModelConfig get config => LocalModelConfig(
    baseUrl: 'http://127.0.0.1:${server.port}/v1',
    model: _model,
  );
  Future<Map<String, String>> raw() async => {
    for (final row in await StoreRef<String, String>('records').find(database!))
      row.key: row.value,
  };

  void serve({bool mismatch = false, _AmbiguousMetadata? ambiguity}) {
    subscription = server.listen((request) async {
      httpCalls++;
      try {
        // Read physical storage immediately, before reading or answering the body.
        final intent = await StoreRef<String, String>('records')
            .record(journalKey)
            .get(database!);
        final reserved = RepairAttemptJournal.fromJson(
          jsonDecode(intent!) as Map<String, dynamic>,
        ).attempts.single;
        expect(reserved.status, RepairAttemptStatus.reserved);
        expect(reserved.modelRequest!.responseModel, isNull);
        final originRaw = await StoreRef<String, String>('records')
            .record(originKey)
            .get(database!);
        final origin = SelectedRepairRequest.decode(originRaw!);
        origin.requireAttempt(reserved);
        expect(
          origin.requestSessionRecord,
          records.getString(binding.session.storageKey),
        );
        expect(request.method, 'POST');
        expect(request.uri.path, '/v1/chat/completions');
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], _model);
        expect(body['max_tokens'], 4096);
        expect(body['stream'], true);
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        final observed = mismatch ? 'synthetic-wrong-repair-response' : _model;
        final terminalAmbiguity =
            ambiguity == _AmbiguousMetadata.terminalPlain ||
            ambiguity == _AmbiguousMetadata.terminalEscaped;
        final escaped =
            ambiguity == _AmbiguousMetadata.escaped ||
            ambiguity == _AmbiguousMetadata.terminalEscaped;
        final duplicateKey = escaped ? r'"\u006dodel"' : '"model"';
        final ambiguousMembers =
            '"model":"synthetic-wrong-repair-response",$duplicateKey:${jsonEncode(_model)}';
        final uniqueMembers = '"model":${jsonEncode(observed)}';
        final supplied = response();
        final split = terminalAmbiguity
            ? supplied.length ~/ 2
            : supplied.length;
        final firstMembers = ambiguity != null && !terminalAmbiguity
            ? ambiguousMembers
            : uniqueMembers;
        request.response.write(
          'data: {$firstMembers,"choices":${jsonEncode([
            {
              'delta': {'content': supplied.substring(0, split)},
            },
          ])}}\n\n',
        );
        if (terminalAmbiguity) {
          // Deliver a valid nonterminal source fragment before the ambiguous end.
          await request.response.flush();
          validPartialFramesFlushed++;
        }
        final terminalMembers = terminalAmbiguity
            ? ambiguousMembers
            : uniqueMembers;
        request.response.write(
          'data: {$terminalMembers,"choices":${jsonEncode([
            {
              'delta': terminalAmbiguity ? {'content': supplied.substring(split)} : {},
              'finish_reason': 'stop',
            },
          ])}}\n\n',
        );
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      } catch (error, stack) {
        callbackError = error;
        callbackStack = stack;
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {
          // Preserve the original callback failure if its connection already closed.
        }
      } finally {
        if (!handled.isCompleted) handled.complete();
      }
    });
  }

  Future<ApprovedSourceProposal> propose({bool refuseReserve = false}) {
    boundary = _ReservationBoundary(records, refuse: refuseReserve);
    service = ApprovedSourceProposer(
      boundary!,
    ); // Uses the default HTTP provider.
    final pending = service!.propose(
      project: project,
      boardTaskId: 'Tanalyze',
      config: config,
      originals: originals,
      repairCandidate: failed,
      repairSessionBinding: binding,
      repairWorkingRecord: working,
    );
    // The test awaits the original future; this separate listener only drains
    // cancellation during cleanup if an earlier assertion fails.
    _settled = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }

  Future<void> requireCallback() async {
    await handled.future.timeout(_wait);
    final error = callbackError;
    if (error != null) Error.throwWithStackTrace(error, callbackStack!);
  }

  Future<void> reopen() async {
    final old = database!;
    database = null;
    await old.close();
    database = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    records = await StudioDatabase.migrate(database!, preferences);
  }

  Future<void> close() async {
    boundary?.releaseIfHeld();
    try {
      await service?.cancel();
    } finally {
      try {
        await _settled?.timeout(_wait);
      } finally {
        try {
          await server.close(force: true);
        } finally {
          try {
            await subscription?.cancel();
            if (httpCalls != 0) await handled.future.timeout(_wait);
          } finally {
            await database?.close();
            database = null;
          }
        }
      }
    }
  }
}

Future<void> _withFixture(Future<void> Function(_Fixture) run) async {
  final previous = HttpOverrides.current;
  HttpOverrides.global =
      null; // Real loopback HTTP, never the owner model service.
  Directory? root;
  Database? database;
  HttpServer? server;
  _Fixture? fixture;
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
    root = await Directory.systemTemp.createTemp('asg-repair-http-journal-');
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    final records = await StudioDatabase.migrate(database, preferences);
    for (final entry in seed.records.values.entries) {
      await records.setString(entry.key, entry.value);
    }
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fixture = _Fixture(
      root,
      preferences,
      database,
      records,
      server,
      binding,
      records.getString('studio.generation.v1.${project.id}')!,
      failed,
    );
    await run(fixture);
  } finally {
    try {
      if (fixture != null) {
        await fixture.close();
      } else {
        try {
          await server?.close(force: true);
        } finally {
          await database?.close();
        }
      }
    } finally {
      try {
        await root?.delete(recursive: true);
      } finally {
        HttpOverrides.global = previous;
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    (label: 'validated return', mismatch: false, ambiguity: null),
    (label: 'wrong response ID', mismatch: true, ambiguity: null),
    (
      label: 'contradictory plain duplicate model',
      mismatch: false,
      ambiguity: _AmbiguousMetadata.plain,
    ),
    (
      label: 'contradictory escaped duplicate model',
      mismatch: false,
      ambiguity: _AmbiguousMetadata.escaped,
    ),
    (
      label: 'plain terminal duplicate after valid partial source',
      mismatch: false,
      ambiguity: _AmbiguousMetadata.terminalPlain,
    ),
    (
      label: 'escaped terminal duplicate after valid partial source',
      mismatch: false,
      ambiguity: _AmbiguousMetadata.terminalEscaped,
    ),
  ]) {
    final invalid = scenario.mismatch || scenario.ambiguity != null;
    test(
      'actual selected repair HTTP/native journal: ${scenario.label}; synthetic SSE only',
      () async {
        await _withFixture((f) async {
          final before = await f.raw();
          f.serve(mismatch: scenario.mismatch, ambiguity: scenario.ambiguity);
          final pending = f.propose();
          await f.boundary!.entered.future.timeout(_wait);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(f.httpCalls, 0);
          expect(f.boundary!.release.isCompleted, isFalse);
          final held = await f.raw();
          final reserved = RepairAttemptJournal.fromJson(
            jsonDecode(held[f.journalKey]!) as Map<String, dynamic>,
          ).attempts.single;
          expect(reserved.status, RepairAttemptStatus.reserved);
          expect(reserved.modelRequest!.model, _model);
          expect(reserved.modelRequest!.outputTokens, 4096);
          final originRaw = held[f.originKey]!,
              origin = SelectedRepairRequest.decode(originRaw);
          origin.requireAttempt(reserved);
          expect(held, {
            ...before,
            f.journalKey: held[f.journalKey]!,
            f.originKey: originRaw,
          });
          f.boundary!.releaseIfHeld();
          ApprovedSourceProposal? evidence;
          Object? refusal;
          try {
            evidence = await pending.timeout(_wait);
          } catch (error) {
            refusal = error;
          }
          await f.requireCallback();
          expect(f.httpCalls, 1);
          expect(
            f.validPartialFramesFlushed,
            scenario.ambiguity == _AmbiguousMetadata.terminalPlain ||
                    scenario.ambiguity == _AmbiguousMetadata.terminalEscaped
                ? 1
                : 0,
          );
          final entry = RepairAttemptStore(
            f.records,
            project.id,
          ).load().attempts.single;
          expect(entry.modelRequest!.model, _model);
          expect(entry.failure.toJson(), reserved.failure.toJson());
          origin.requireAttempt(entry);
          expect(entry.modelRequest!.responseModel, invalid ? null : _model);
          if (invalid) {
            expect(refusal, anyOf(isA<FormatException>(), isA<StateError>()));
            expect(evidence, isNull);
            expect(entry.status, RepairAttemptStatus.failed);
            expect(entry.proposal, isNull);
          } else {
            expect(refusal, isNull);
            expect(evidence!.modelRequest!.responseModel, _model);
            expect(entry.status, RepairAttemptStatus.proposed);
            evidence.repairRequestReference!.requireMatch(origin, entry);
          }
          final raw = f.records.getString(f.journalKey)!, after = await f.raw();
          expect(after, {...before, f.journalKey: raw, f.originKey: originRaw});
          await f.reopen();
          expect(await f.raw(), after);
          final retained = RepairAttemptStore(
            f.records,
            project.id,
          ).load().attempts.single;
          expect(retained.toJson(), entry.toJson());
          origin.requireAttempt(retained);
          final page = SelectedRepairRequestStore(
            f.records,
            project.id,
          ).load(f.binding.session.sessionId);
          expect(page.entries.single.origin!.encode(), originRaw);
          if (invalid) {
            expect(page.entries.single.reference, isNull);
          } else {
            page.entries.single.reference!.requireMatch(origin, entry);
          }
          expect(f.httpCalls, 1);
        });
      },
    );
  }
  test('repair reservation refusal sends no HTTP and leaves neither origin nor journal', () async {
    await _withFixture((f) async {
      final before = await f.raw();
      f.serve();
      await expectLater(
        f.propose(refuseReserve: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reservation refusal',
            'Supplied reservation persistence refusal.',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(f.httpCalls, 0);
      expect(await f.raw(), before);
      expect(f.records.getString(f.journalKey), isNull);
      expect(f.records.getString(f.originKey), isNull);
      await f.reopen();
      expect(await f.raw(), before);
      expect(f.httpCalls, 0);
    });
  });
}

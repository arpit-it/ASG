// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_session_binding.dart';
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
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

enum _ResponseCase {
  valid,
  wrongId,
  duplicateId,
  escapedDuplicateId,
  terminalDuplicateId,
  terminalEscapedDuplicateId,
}

const _model = 'synthetic-http-initial-metadata';
const _after = 'void main() { print("Hi"); }';
const _wait = Duration(seconds: 10);

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
        updates.keys.any(
          (key) => key.startsWith(SessionProposalRequestStore.prefix),
        );
    if (reserve) {
      _seen = true;
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
  );
  final Directory root;
  final SharedPreferences preferences;
  Database? database;
  StudioDatabase records;
  final HttpServer server;
  final AgentSessionBinding binding;
  final String working;
  ApprovedSourceProposer? service;
  Future<void>? _settled;
  _ReservationBoundary? boundary;
  StreamSubscription<HttpRequest>? subscription;
  final handled = Completer<void>();
  Object? callbackError;
  StackTrace? callbackStack;
  int httpCalls = 0;

  String get journalKey =>
      '${SessionProposalRequestStore.prefix}${project.id}.${binding.session.sessionId}';
  LocalModelConfig get config => LocalModelConfig(
    baseUrl: 'http://127.0.0.1:${server.port}/v1',
    model: _model,
  );
  Future<Map<String, String>> raw() async => {
    for (final row in await StoreRef<String, String>('records').find(database!))
      row.key: row.value,
  };

  void serve({
    _ResponseCase responseCase = _ResponseCase.valid,
    bool jsonResponse = false,
    bool omitModel = false,
  }) {
    subscription = server.listen((request) async {
      httpCalls++;
      try {
        // Read physical storage immediately, before reading or answering the body.
        final intent = await StoreRef<String, String>('records')
            .record(journalKey)
            .get(database!);
        final reserved = SessionProposalRequestJournal.decode(intent!)
            .requests
            .single;
        expect(reserved.status, SessionProposalRequestStatus.reserved);
        expect(reserved.modelRequest.responseModel, isNull);
        expect(request.method, 'POST');
        expect(request.uri.path, '/v1/chat/completions');
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], _model);
        expect(body['max_tokens'], 4096);
        expect(body['stream'], true);
        request.response.headers.contentType = jsonResponse
            ? ContentType.json
            : ContentType('text', 'event-stream', charset: 'utf-8');
        final observed = responseCase == _ResponseCase.wrongId
            ? 'synthetic-wrong-response'
            : _model;
        String frame(Map<String, Object?> data, {required bool terminal}) {
          final raw = jsonEncode(data);
          final ambiguous = terminal
              ? responseCase == _ResponseCase.terminalDuplicateId ||
                    responseCase == _ResponseCase.terminalEscapedDuplicateId
              : responseCase == _ResponseCase.duplicateId ||
                    responseCase == _ResponseCase.escapedDuplicateId;
          if (!ambiguous) return raw;
          final escaped =
              responseCase == _ResponseCase.escapedDuplicateId ||
              responseCase == _ResponseCase.terminalEscapedDuplicateId;
          return raw.replaceFirst(
            '"model":',
            escaped
                ? r'"model":"synthetic-foreign","\u006dodel":'
                : '"model":"synthetic-foreign","model":',
          );
        }

        if (jsonResponse) {
          request.response.write(
            frame({
              if (!omitModel) 'model': observed,
              'choices': [
                {
                  'message': {'content': response()},
                  'finish_reason': 'stop',
                },
              ],
            }, terminal: false),
          );
          await request.response.close();
          return;
        }
        final terminalAmbiguity =
            responseCase == _ResponseCase.terminalDuplicateId ||
            responseCase == _ResponseCase.terminalEscapedDuplicateId;
        final supplied = response();
        final split = terminalAmbiguity
            ? supplied.length ~/ 2
            : supplied.length;
        request.response.write(
          'data: ${frame({
            'model': observed,
            'choices': [
              {
                'delta': {'content': supplied.substring(0, split)},
              },
            ],
          }, terminal: false)}\n\n',
        );
        if (terminalAmbiguity) {
          // Send the valid source frame before the ambiguous terminal frame.
          await request.response.flush();
        }
        request.response.write(
          'data: ${frame({
            'model': observed,
            'choices': [
              {
                'delta': terminalAmbiguity ? {'content': supplied.substring(split)} : {},
                'finish_reason': 'stop',
              },
            ],
          }, terminal: true)}\n\n',
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
      sessionBinding: binding,
      requestWorkingRecord: working,
      authorizeSession: () {},
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
    final seed = AtomicRecords();
    final selected = await initialContext(seed);
    root = await Directory.systemTemp.createTemp('asg-initial-http-journal-');
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    final records = await StudioDatabase.migrate(database, preferences);
    for (final entry in seed.values.entries) {
      await records.setString(entry.key, entry.value);
    }
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fixture = _Fixture(
      root,
      preferences,
      database,
      records,
      server,
      selected.binding,
      selected.working,
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
  for (final (responseCase, jsonResponse, omitModel) in [
    for (final value in _ResponseCase.values) (value, false, false),
    for (final value in _ResponseCase.values.take(4)) (value, true, false),
    (_ResponseCase.valid, true, true),
  ]) {
    final mismatch = responseCase != _ResponseCase.valid;
    test(
      'actual HTTP and native initial journal: ${omitModel ? 'missingId' : responseCase.name}; supplied ${jsonResponse ? 'JSON compatibility' : 'SSE'} only',
      () async {
        await _withFixture((f) async {
          final before = await f.raw();
          f.serve(
            responseCase: responseCase,
            jsonResponse: jsonResponse,
            omitModel: omitModel,
          );
          final pending = f.propose();
          await f.boundary!.entered.future.timeout(_wait);
          // Give real socket I/O an opportunity to arrive while completion stays held.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(f.boundary!.release.isCompleted, isFalse);
          expect(
            f.httpCalls,
            0,
            reason: 'Transport waits for durable reservation completion.',
          );
          final intent = await StoreRef<String, String>('records')
              .record(f.journalKey)
              .get(f.database!);
          expect(
            SessionProposalRequestJournal.decode(intent!)
                .requests
                .single
                .status,
            SessionProposalRequestStatus.reserved,
          );
          f.boundary!.releaseIfHeld();
          ApprovedSourceProposal? evidence;
          Object? refusal;
          try {
            evidence = await pending.timeout(_wait);
          } catch (error) {
            refusal = error;
          }
          await f.requireCallback(); // Callback assertions must never be swallowed.
          expect(f.httpCalls, 1);
          if (mismatch) {
            expect(refusal, anyOf(isA<FormatException>(), isA<StateError>()));
            expect(evidence, isNull);
          } else {
            expect(refusal, isNull);
            expect(
              evidence!.modelRequest!.responseModel,
              omitModel ? null : _model,
            );
            expect(evidence.initialRequestOrigin!.reference.number, 1);
            expect(
              evidence.initialRequestOrigin!.requestSessionRecord,
              before[f.binding.session.storageKey],
            );
          }
          final raw = f.records.getString(f.journalKey)!;
          final after = await f.raw();
          expect(after, {...before, f.journalKey: raw});
          expect(
            f.records.getString('studio.candidateChecks.v1.${project.id}'),
            isNull,
          );
          expect(
            jsonDecode(raw).toString().contains(_after),
            isFalse,
            reason: 'History retains hashes, not restored source.',
          );
          await f.reopen();
          final retained = SessionProposalRequestStore(
            f.records,
            project.id,
            f.binding.session.sessionId,
          ).load().requests.single;
          expect(
            retained.status,
            mismatch
                ? SessionProposalRequestStatus.failedLocally
                : SessionProposalRequestStatus.returnedValidated,
          );
          expect(retained.modelRequest.model, _model);
          if (mismatch) {
            expect(retained.modelRequest.responseModel, isNull);
            expect(retained.returnedSha256, isEmpty);
          } else {
            expect(
              retained.modelRequest.responseModel,
              omitModel ? null : _model,
            );
            expect(
              retained.sessionSha256,
              SessionProposalRequestStore.fingerprint(
                before[f.binding.session.storageKey]!,
              ),
            );
            expect(retained.returnedSha256, {
              'lib/main.dart': SessionProposalRequestStore.fingerprint(_after),
            });
            expect(
              evidence!.initialRequestOrigin!.reference.matches(retained),
              isTrue,
            );
          }
          expect(f.records.getString(f.journalKey), raw);
          expect(await f.raw(), after);
          expect(f.httpCalls, 1, reason: 'Native reopen must not replay HTTP.');
        });
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
  test('native reserve persistence refusal sends no HTTP and leaves no partial records', () async {
    await _withFixture((f) async {
      final before = await f.raw();
      f.serve();
      await expectLater(
        f.propose(refuseReserve: true).timeout(_wait),
        throwsStateError,
      );
      expect(f.httpCalls, 0);
      expect(f.records.getString(f.journalKey), isNull);
      expect(await f.raw(), before);
      await f.reopen();
      expect(await f.raw(), before);
      expect(f.httpCalls, 0);
    });
  }, timeout: const Timeout(Duration(seconds: 30)));
}

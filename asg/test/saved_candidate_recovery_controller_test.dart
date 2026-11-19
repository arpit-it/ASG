// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/services/agent_session_admission.dart';
import 'package:asg/services/candidate_request_lineage_store.dart';

import 'package:asg/services/application_store.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/generation_host_native.dart';

import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/controllers/saved_candidate_recovery_controller.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/candidate_reopen_context_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/generation_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_request_lineage_test.dart' show lineageFixture;
import 'candidate_reopen_context_test.dart' show ReopenFixture, reopenFixture;
import 'candidate_reopen_context_store_test.dart' show startReopen;
import 'planning_conversation_test.dart' show project, tick;
import 'source_candidate_controller_test.dart' show IntentCheckHost;

class ReopenInspectionHost extends IntentCheckHost
    implements CandidateSourceInspectionHost {
  final checked = <String>[];
  Completer<void>? sourceGate;
  bool failSource = false;
  int disposals = 0;
  @override
  Future<void> checkSources(GeneratedProject project) async {
    checked.add(project.directory);
    await sourceGate?.future;
    if (failSource) throw StateError('private prompt token /private/source');
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await super.dispose();
  }
}

Future<({ReopenFixture fixture, CandidateVerificationStore journal})>
admittedReopen({bool pending = false}) async {
  final f = await reopenFixture();
  final journal = CandidateVerificationStore(f.records, project.id);
  final run = await startReopen(f, journal);
  if (pending) {
    await journal.checkpoint(
      run.snapshot.copy(pendingOperation: 'resolve'),
      () {},
    );
  }
  return (fixture: f, journal: journal);
}

void main() {
  test('exact initial origin survives Stop acknowledgement, reopen and explicit retry without another proposal', () async {
    final f = await lineageFixture(formatted: true);
    final journal = CandidateVerificationStore(f.records, project.id);
    final run = await journal.start(
      f.basis.prepared.copy(phase: SourceGenerationPhase.verifying, steps: []),
      () {},
      reopenBasis: f.basis,
      initialRequestOrigin: f.origin,
      sessionAdmission: AgentSessionRunAdmission(
        f.records,
        project,
        AgentSessionBinding.select(
          session: f.origin.requestSession,
          projectId: project.id,
          boardTaskId: f.request.boardTaskId,
        ),
      ),
    );
    await journal.checkpoint(
      run.snapshot.copy(pendingOperation: 'resolve'),
      () {},
    );
    await journal.requestStop(DateTime.now().toUtc());
    final requestKey =
        'studio.sessionProposalRequests.v1.${project.id}.${f.request.sessionId}';
    final originalRequests = f.records.getString(requestKey);
    final working = f.records.getString('studio.generation.v1.${project.id}');
    final hosts = <ReopenInspectionHost>[];
    final c = SavedCandidateRecoveryController(
      project: project,
      records: f.records,
      selectedSession: journal.admittedSession!,
      runNumber: 1,
      createHost: () {
        final h = ReopenInspectionHost();
        hosts.add(h);
        return h;
      },
    );
    await c.open();
    expect(c.error, isNull);
    expect(
      c.evidence!.initialRequestOrigin!.requestSessionRecord,
      f.origin.requestSessionRecord,
    );
    final candidate = c.candidate!;
    await candidate.verify(approved: false);
    expect(hosts.last.verifications, 0);
    await candidate.acknowledgeStopped(candidate.history.single);
    expect(candidate.error, isNull);
    await candidate.verify(approved: true);
    expect(candidate.error, isNull);
    expect(candidate.history, hasLength(2));
    final second = CandidateRequestLineageStore(
      f.records,
      project.id,
    ).load(candidate.history.last)!;
    expect(
      second.lineage.origin.reference.encode(),
      f.origin.reference.encode(),
    );
    expect(
      second.lineage.origin.requestSessionRecord,
      f.origin.requestSessionRecord,
    );
    expect(second.lineage.admissionSession.dispatches, hasLength(1));
    expect(second.lineage.origin.requestSession.dispatches, isEmpty);
    expect(f.records.getString(requestKey), originalRequests);
    expect(f.records.getString('studio.generation.v1.${project.id}'), working);
    expect(hosts.last.verifications, 1);
    c.dispose();
  });

  test(
    'actual native source inspection opens without SDK execution and refuses changed files',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'asg-reopen-inspection-',
      );
      final root = Directory(await temporary.resolveSymbolicLinks());
      SavedCandidateRecoveryController? recovery;
      try {
        final f = await reopenFixture(
          workingDirectory: '${root.path}/working',
          candidateDirectory: '${root.path}/candidate',
        );
        final input = GenerationInput(
          project,
          ApplicationStore(f.records).load(project).definition,
        );
        for (final snapshot in [f.basis.working, f.basis.prepared]) {
          final texts = <String, String>{
            'assets/app.json': input.applicationJson,
            'asg_project.json': input.metadataJson,
            'lib/main.dart': snapshot.directory == f.basis.working.directory
                ? f.basis.evidence.proposal.changes.single.before
                : f.basis.evidence.proposal.changes.single.after,
          };
          for (final entry in texts.entries) {
            final file = File('${snapshot.directory}/${entry.key}');
            await file.parent.create(recursive: true);
            await file.writeAsString(entry.value);
          }
        }
        final journal = CandidateVerificationStore(f.records, project.id);
        await startReopen(f, journal);
        var commands = 0, assets = 0;
        NativeGenerationHost createHost() => NativeGenerationHost(
          runOperation: (_, _) async {
            commands++;
            throw StateError('No command authorized by opening');
          },
          loadAsset: (_) async {
            assets++;
            throw StateError('No preparation authorized by opening');
          },
        );
        final before = Map.of(f.records.values);
        recovery = SavedCandidateRecoveryController(
          project: project,
          records: f.records,
          selectedSession: journal.admittedSession!,
          runNumber: 1,
          createHost: createHost,
        );
        await recovery.open();
        expect(recovery.error, isNull);
        expect(recovery.candidate, isNotNull);
        expect(commands, 0);
        expect(assets, 0);
        expect(f.records.values, before);
        recovery.dispose();
        await tick();
        final file = File('${f.basis.prepared.directory}/lib/main.dart');
        await file.writeAsString('changed after admission');
        recovery = SavedCandidateRecoveryController(
          project: project,
          records: f.records,
          selectedSession: journal.admittedSession!,
          runNumber: 1,
          createHost: createHost,
        );
        await recovery.open();
        expect(recovery.candidate, isNull);
        expect(recovery.error, isNotNull);
        expect(await file.readAsString(), 'changed after admission');
        expect(commands, 0);
        expect(assets, 0);
        expect(f.records.values, before);
      } finally {
        recovery?.dispose();
        await tick();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS
        ? 'Native macOS host acceptance remains deferred under #400 on unavailable hosts.'
        : false,
  );

  test(
    'opening inspects distinct owned hosts without new work or record mutation',
    () async {
      final a = await admittedReopen();
      final f = a.fixture;
      final hosts = <ReopenInspectionHost>[];
      final c = SavedCandidateRecoveryController(
        project: project,
        records: f.records,
        selectedSession: a.journal.admittedSession!,
        runNumber: 1,
        createHost: () {
          final h = ReopenInspectionHost();
          hosts.add(h);
          return h;
        },
      );
      final before = Map.of(f.records.values);
      await c.open();
      expect(c.error, isNull);
      expect(c.candidate, isNotNull);
      expect(c.actionsEnabled, isTrue);
      expect(hosts.map((h) => h.checked.single), ['/working', '/candidate']);
      expect(
        hosts.every(
          (h) => h.verifications == 0 && h.generations == 0 && !h.server,
        ),
        isTrue,
      );
      expect(f.records.values, before);
      c.dispose();
      await tick();
      expect(hosts.map((h) => h.disposals), [1, 1]);
    },
  );

  test('host without read-only source inspection keeps history and grants no actions', () async {
    final a = await admittedReopen();
    final before = Map.of(a.fixture.records.values);
    final hosts = <IntentCheckHost>[];
    final c = SavedCandidateRecoveryController(
      project: project,
      records: a.fixture.records,
      selectedSession: a.journal.admittedSession!,
      runNumber: 1,
      createHost: () {
        final host = IntentCheckHost();
        hosts.add(host);
        return host;
      },
    );
    await c.open();
    expect(c.error, contains('unavailable on this host'));
    expect(c.candidate, isNull);
    expect(c.actionsEnabled, isFalse);
    expect(hosts, hasLength(2));
    expect(
      hosts.every(
        (h) => h.verifications == 0 && h.generations == 0 && !h.server,
      ),
      isTrue,
    );
    expect(a.fixture.records.values, before);
    c.dispose();
  });

  test('source failure and changed authority during inspection retain records and sanitize errors', () async {
    for (final changed in [false, true]) {
      final a = await admittedReopen();
      final f = a.fixture;
      final gate = Completer<void>();
      final hosts = <ReopenInspectionHost>[];
      final c = SavedCandidateRecoveryController(
        project: project,
        records: f.records,
        selectedSession: a.journal.admittedSession!,
        runNumber: 1,
        createHost: () {
          final h = ReopenInspectionHost();
          if (hosts.isEmpty) {
            h.sourceGate = gate;
            h.failSource = !changed;
          }
          hosts.add(h);
          return h;
        },
      );
      final opening = c.open();
      await tick();
      if (changed) {
        await AgentSessionStore(
          f.records,
          project,
        ).requestCancellation(a.journal.admittedSession!);
      }
      final before = Map.of(f.records.values);
      gate.complete();
      await opening;
      expect(c.candidate, isNull);
      expect(c.actionsEnabled, isFalse);
      expect(c.error, isNotNull);
      expect(c.error, isNot(contains('private prompt')));
      expect(
        hosts.every((h) => h.disposals == 1 && h.verifications == 0),
        isTrue,
      );
      expect(f.records.values, before);
      c.dispose();
    }
  });

  test('disposal during source inspection suppresses late controller publication and updates', () async {
    final a = await admittedReopen();
    final gate = Completer<void>();
    final hosts = <ReopenInspectionHost>[];
    final c = SavedCandidateRecoveryController(
      project: project,
      records: a.fixture.records,
      selectedSession: a.journal.admittedSession!,
      runNumber: 1,
      createHost: () {
        final h = ReopenInspectionHost();
        if (hosts.isEmpty) h.sourceGate = gate;
        hosts.add(h);
        return h;
      },
    );
    var notifications = 0;
    c.addListener(() {
      notifications++;
    });
    final before = Map.of(a.fixture.records.values);
    final opening = c.open();
    await tick();
    c.dispose();
    final count = notifications;
    gate.complete();
    await opening;
    expect(c.candidate, isNull);
    expect(notifications, count);
    expect(
      hosts.every((h) => h.disposals == 1 && h.verifications == 0),
      isTrue,
    );
    expect(hosts.last.checked, isEmpty);
    expect(a.fixture.records.values, before);
  });

  test('cancellation or context change after open blocks effects without unbound fallback', () async {
    for (final contextChange in [false, true]) {
      final a = await admittedReopen();
      final hosts = <ReopenInspectionHost>[];
      final c = SavedCandidateRecoveryController(
        project: project,
        records: a.fixture.records,
        selectedSession: a.journal.admittedSession!,
        runNumber: 1,
        createHost: () {
          final h = ReopenInspectionHost();
          hosts.add(h);
          return h;
        },
      );
      await c.open();
      expect(c.actionsEnabled, isTrue);
      if (contextChange) {
        a.fixture.records.values[c.context!.storageKey] = '{retained damaged';
      } else {
        await AgentSessionStore(
          a.fixture.records,
          project,
        ).requestCancellation(a.journal.admittedSession!);
      }
      final before = Map.of(a.fixture.records.values);
      expect(c.actionsEnabled, isFalse);
      await c.candidate!.verify(approved: true);
      expect(hosts.last.verifications, 0);
      expect(a.fixture.records.values, before);
      c.dispose();
    }
  });

  test('explicit acknowledgment and new-consent retry retain original context and allow guarded promotion', () async {
    final a = await admittedReopen(pending: true);
    final f = a.fixture;
    final hosts = <ReopenInspectionHost>[];
    final c = SavedCandidateRecoveryController(
      project: project,
      records: f.records,
      selectedSession: a.journal.admittedSession!,
      runNumber: 1,
      createHost: () {
        final h = ReopenInspectionHost();
        hosts.add(h);
        return h;
      },
    );
    await c.open();
    expect(c.error, isNull);
    final original = f.records.getString(c.context!.storageKey);
    final working = f.records.getString('studio.generation.v1.${project.id}');
    final candidate = c.candidate!;
    final before = Map.of(f.records.values);
    await candidate.verify(approved: false);
    expect(f.records.values, before);
    await candidate.acknowledgeStopped(candidate.history.single);
    expect(candidate.error, isNull);
    expect(c.actionsEnabled, isTrue);
    await candidate.verify(approved: true);
    expect(candidate.error, isNull);
    expect(candidate.history.length, 2);
    expect(hosts.last.verifications, 1);
    expect(f.records.getString(c.context!.storageKey), original);
    expect(f.records.getString('studio.generation.v1.${project.id}'), working);
    final latest = CandidateReopenContextStore(
      f.records,
      project,
    ).loadLatest(candidate.sessionBinding!.session, 2);
    expect(latest.runNumber, 2);
    expect(c.actionsEnabled, isTrue);
    final publicationKey = 'studio.agentSessionPublication.v1.${project.id}.2';
    expect(f.records.getString(publicationKey), isNull);
    expect(await candidate.promote(approved: true), isTrue);
    expect(f.records.getString(publicationKey), isNotNull);
    expect(
      f.records.getString('studio.generationPrevious.v1.${project.id}'),
      working,
    );
    expect(
      f.records.getString('studio.generation.v1.${project.id}'),
      isNot(working),
    );
    c.dispose();
  });

  test('promotion cancellation race preserves original working output and session CAS', () async {
    final a = await admittedReopen();
    final f = a.fixture;
    final hosts = <ReopenInspectionHost>[];
    final c = SavedCandidateRecoveryController(
      project: project,
      records: f.records,
      selectedSession: a.journal.admittedSession!,
      runNumber: 1,
      createHost: () {
        final h = ReopenInspectionHost();
        hosts.add(h);
        return h;
      },
    );
    await c.open();
    // The fixture's original admitted run has no unknown pending operation.
    await c.candidate!.verify(approved: true);
    expect(c.candidate!.error, isNull);
    final working = f.records.getString('studio.generation.v1.${project.id}');
    f.records.beforeCommit = () async {
      f.records.beforeCommit = null;
      await AgentSessionStore(
        f.records,
        project,
      ).requestCancellation(c.candidate!.sessionBinding!.session);
    };
    expect(await c.candidate!.promote(approved: true), isFalse);
    expect(f.records.getString('studio.generation.v1.${project.id}'), working);
    expect(
      f.records.getString('studio.generationPrevious.v1.${project.id}'),
      isNull,
    );
    expect(hosts.last.server, isFalse);
    expect(
      f.records.getString('studio.agentSessionPublication.v1.${project.id}.2'),
      isNull,
    );
    c.dispose();
  });

  test('saved session entry does not create hosts and missing context stays unavailable', () async {
    final a = await admittedReopen();
    var hosts = 0;
    final sessions = AgentSessionController(
      AgentSessionStore(a.fixture.records, project),
      createRecoveryHost: () {
        hosts++;
        return ReopenInspectionHost();
      },
    );
    sessions.load();
    sessions.open(a.journal.admittedSession!.sessionId);
    final before = Map.of(a.fixture.records.values);
    expect(sessions.canOpenCandidate(1), isTrue);
    final recovery = sessions.createCandidateRecovery(1)!;
    expect(hosts, 0);
    expect(a.fixture.records.values, before);
    a.fixture.records.values.remove(
      '${CandidateReopenContextStore.prefix}${project.id}.1',
    );
    expect(sessions.canOpenCandidate(1), isFalse);
    expect(sessions.createCandidateRecovery(1), isNull);
    recovery.dispose();
    sessions.dispose();
  });
}

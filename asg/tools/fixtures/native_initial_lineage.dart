// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/controllers/saved_candidate_recovery_controller.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/session_proposal_reference.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_session_run_status_store.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/candidate_request_lineage_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/generation_host.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/session_proposal_request_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';

import 'package:asg/models/structured_proposal_json.dart';
import 'package:path/path.dart' as path;

enum NativeInitialLineageBoundary { precommit, postcommit }

/// Fixed opt-in fixture input only. Parsing grants no tool or storage authority.
final class NativeInitialLineageChallenge {
  const NativeInitialLineageChallenge._({
    required this.nonce,
    required this.launch,
    required this.boundary,
    required this.corruptOptional,
    required this.sdk,
  });

  static const mode = 'initial-lineage';
  static const protocolVersion = 23;
  static const maxEncodedBytes = 4096;
  static const suppliedModel = 'supplied-native-initial-lineage-model';
  final String nonce, sdk;
  final int launch;
  final NativeInitialLineageBoundary boundary;
  final bool corruptOptional;

  String get projectId => 'restart-$nonce';
  String get sessionId => 'session-$nonce';
  int get targetRunNumber => launch >= 3 ? 2 : 1;
  String get targetDispatchId => 'candidate-$projectId-$targetRunNumber:3';
  String get targetCompanionKey =>
      'studio.candidateRequestLineage.v1.$projectId.$targetRunNumber';
  String get stage => switch (launch) {
    1 => 'paused',
    2 => 'read-only',
    3 => 'retry-paused',
    _ => 'retry-read-only',
  };

  factory NativeInitialLineageChallenge.decode(String raw) {
    try {
      if (utf8.encode(raw).length > maxEncodedBytes) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      return NativeInitialLineageChallenge.fromJson(jsonDecode(raw));
    } catch (_) {
      throw const FormatException('Invalid native initial-lineage challenge.');
    }
  }

  factory NativeInitialLineageChallenge.fromJson(Object? value) {
    const keys = {
      'mode',
      'nonce',
      'launch',
      'boundary',
      'corruptOptional',
      'sdk',
    };
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !keys.every(value.containsKey) ||
        value['mode'] != mode ||
        value['nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['nonce'] as String) ||
        value['launch'] is! int ||
        (value['launch'] as int) < 1 ||
        (value['launch'] as int) > 4 ||
        !['precommit', 'postcommit'].contains(value['boundary']) ||
        value['corruptOptional'] is! bool ||
        value['sdk'] is! String) {
      throw const FormatException('Invalid native initial-lineage fields.');
    }
    final launch = value['launch'] as int;
    final sdk = value['sdk'] as String;
    final before = value['boundary'] == 'precommit';
    final corrupt = value['corruptOptional'] as bool;
    if ((before && launch > 2) ||
        (corrupt && (before || launch != 2)) ||
        sdk.isEmpty ||
        sdk.contains(RegExp(r'[\x00\r\n]')) ||
        !path.posix.isAbsolute(sdk) ||
        path.posix.normalize(sdk) != sdk ||
        utf8.encode(jsonEncode(value)).length > maxEncodedBytes) {
      throw const FormatException('Invalid native initial-lineage scope.');
    }
    return NativeInitialLineageChallenge._(
      nonce: value['nonce'] as String,
      launch: launch,
      boundary: before
          ? NativeInitialLineageBoundary.precommit
          : NativeInitialLineageBoundary.postcommit,
      corruptOptional: corrupt,
      sdk: sdk,
    );
  }

  Map<String, Object> toJson() => {
    'mode': mode,
    'nonce': nonce,
    'launch': launch,
    'boundary': boundary.name,
    'corruptOptional': corruptOptional,
    'sdk': sdk,
  };
}

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
String _mapHash(Map<String, String> value) => _hash(
  jsonEncode({for (final key in value.keys.toList()..sort()) key: value[key]}),
);
const _before = 'void main() {}';
const _after = 'void main() { /* supplied native initial proposal */ }';
const _unchanged = 'const fixtureUnchanged = true;';
const _counterNames = [
  'setupProviderCalls',
  'sourceSetupCalls',
  'requestSetupCalls',
  'hostCreations',
  'recoverySourceInspections',
  'startupCalls',
  'startupRecordUpdates',
  'startupReturns',
  'hostEntries',
  'receiptPreparations',
  'liveModelTransportAttempts',
  'sourceCopies',
  'sdkAttempts',
  'previewAttempts',
  'unrelatedRecordWrites',
  'corruptionControls',
];

class _SuppliedInitialProvider
    implements ModelProvider, ModelResponseIdentityProvider {
  @override
  String get completedResponseModel =>
      NativeInitialLineageChallenge.suppliedModel;
  @override
  Stream<String> generate(String prompt) => Stream.value(
    jsonEncode({
      'summary': 'Supplied native initial proposal metadata',
      'changes': [
        {'path': 'lib/main.dart', 'before': _before, 'after': _after},
      ],
    }),
  );
  @override
  Future<void> cancel() async {}
}

/// Inspection is real and bounded to the supplied sources. Every execution entry
/// fails closed; the startup barrier must prevent these methods being reached.
class _InspectionHost extends NativeGenerationHost {
  _InspectionHost(this.counts);
  final Map<String, int> counts;
  @override
  Future<void> checkSources(GeneratedProject project) async {
    counts['recoverySourceInspections'] =
        counts['recoverySourceInspections']! + 1;
    await super.checkSources(project);
  }

  @override
  Future<void> prepareCandidateReceipts(
    CandidateVerificationRun run,
    void Function() authorize,
  ) async {
    counts['receiptPreparations'] = counts['receiptPreparations']! + 1;
    throw StateError('No receipt entry is supplied.');
  }

  @override
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  }) async {
    counts['hostEntries'] = counts['hostEntries']! + 1;
    counts['sdkAttempts'] = counts['sdkAttempts']! + 1;
    throw StateError('No SDK execution is supplied.');
  }

  @override
  Future<Uri> startPreview(GeneratedProject project) async {
    counts['previewAttempts'] = counts['previewAttempts']! + 1;
    throw StateError('No preview is supplied.');
  }
}

class _StartupPause implements ConditionalRecordStorage {
  _StartupPause(this.delegate, this.input, this.counts, this.onPause);
  final StudioDatabase delegate;
  final NativeInitialLineageChallenge input;
  final Map<String, int> counts;
  final Future<void> Function() onPause;
  @override
  String? getString(String key) => delegate.getString(key);
  @override
  Future<bool> setString(String key, String value) async {
    counts['unrelatedRecordWrites'] = counts['unrelatedRecordWrites']! + 1;
    throw StateError('No unrelated write is supplied after setup.');
  }

  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    if (updates.isEmpty) {
      return delegate.commitRecords(
        expected: expected,
        updates: updates,
        authorize: authorize,
      );
    }
    final slots = _slots(input);
    final n = input.targetRunNumber;
    final cohort = {
      'journal',
      'candidate',
      'session',
      'execution$n',
      'history$n',
      'context$n',
      'companion$n',
    };
    if (updates.length != cohort.length ||
        !cohort.every((key) => updates.containsKey(slots[key]))) {
      counts['unrelatedRecordWrites'] = counts['unrelatedRecordWrites']! + 1;
      throw StateError('Unexpected fixture startup update cohort.');
    }
    if (input.boundary == NativeInitialLineageBoundary.postcommit) {
      await delegate.commitRecords(
        expected: expected,
        updates: updates,
        authorize: authorize,
      );
      counts['startupRecordUpdates'] = updates.length;
    } else {
      authorize();
    }
    await onPause();
    throw StateError('Fixture startup pause must not return.');
  }
}

Map<String, String> _slots(NativeInitialLineageChallenge c) => {
  'working': 'studio.generation.v1.${c.projectId}',
  'requestJournal':
      '${SessionProposalRequestStore.prefix}${c.projectId}.${c.sessionId}',
  'journal': 'studio.candidateChecks.v1.${c.projectId}',
  'candidate': 'studio.sourceCandidate.v1.${c.projectId}',
  'session': 'studio.agentSession.v1.${c.projectId}.${c.sessionId}',
  for (final n in [1, 2]) ...{
    'execution$n': 'studio.agentExecution.v1.candidate-${c.projectId}-$n',
    'history$n': 'studio.agentTaskHistory.v1.${c.projectId}.$n',
    'context$n': 'studio.candidateReopen.v1.${c.projectId}.$n',
    'companion$n': 'studio.candidateRequestLineage.v1.${c.projectId}.$n',
    'repairCompanion$n': 'studio.candidateRepairLineage.v1.${c.projectId}.$n',
  },
};
Future<Map<String, String>> _raw(Database db) async => {
  for (final row in await StoreRef<String, String>('records').find(db))
    row.key: row.value,
};
Map<String, String?> _slotHashes(
  Map<String, String> raw,
  NativeInitialLineageChallenge c,
) => {
  for (final e in _slots(c).entries)
    e.key: raw[e.value] == null ? null : _hash(raw[e.value]!),
};
String _unrelated(Map<String, String> raw, NativeInitialLineageChallenge c) =>
    _mapHash({
      for (final e in raw.entries)
        if (!_slots(c).values.contains(e.key)) e.key: e.value,
    });
StudioProject _project(NativeInitialLineageChallenge c) => StudioProject(
  id: c.projectId,
  name: 'Supplied native initial proposal lineage',
  description: 'Fixed metadata only',
  type: 'Flutter',
  platforms: const ['Web'],
  location: '',
);

typedef _Setup = ({
  GeneratedProject working,
  GeneratedProject prepared,
  ApprovedSourceProposal evidence,
});
Future<_Setup> _setup(
  StudioDatabase records,
  NativeInitialLineageChallenge c,
  String root,
  Map<String, int> counts,
) async {
  final project = _project(c);
  await StudioStore(records).save([project]);
  const ops = ['resolve', 'test', 'analyze', 'build'];
  const dependencies = <String, List<String>>{
    'resolve': [],
    'test': ['resolve'],
    'analyze': ['resolve'],
    'build': ['test', 'analyze'],
  };
  final board = RequirementsBoard(
    requirements: [
      ProjectRequirement(
        id: 'R1',
        title: 'Native metadata',
        acceptance: 'Inspect exact initial request lineage',
      ),
    ],
    tasks: [
      for (final op in ops)
        DevelopmentTask(
          id: 'T$op',
          requirementId: 'R1',
          title: op,
          dependencies: dependencies[op]!.map((d) => 'T$d').toList(),
        ),
    ],
  );
  final boards = RequirementsStore(records);
  await boards.save(project.id, boards.load(project.id), board);
  final content =
      '```asg-build\n${jsonEncode({
        'version': 3,
        'adapter': 'flutter-starter',
        'tasks': [
          for (final op in ops) {'id': op, 'operation': op, 'boardTaskId': 'T$op', 'dependencies': dependencies[op]},
        ],
      })}\n```';
  final approvals = PlanApprovalStore(records);
  final messages = [
    ChatMessage(
      role: 'assistant',
      content: content,
      planContext: approvals.contextFor(project),
    ),
  ];
  await ConversationStore(records).save(project.id, messages);
  await approvals.save(project, messages, true);
  final approval = approvals.requireCurrentApproval(project);
  final input = GenerationInput(
    project,
    ApplicationStore(records).load(project).definition,
  );
  for (final (folder, main) in [('working', _before), ('candidate', _after)]) {
    for (final e in {
      'lib/main.dart': main,
      'lib/unchanged.dart': _unchanged,
      'assets/app.json': input.applicationJson,
      'asg_project.json': input.metadataJson,
    }.entries) {
      final f = File(path.join(root, folder, e.key));
      await f.parent.create(recursive: true);
      await f.writeAsString(e.value, flush: true);
    }
  }
  counts['sourceSetupCalls'] = 1;
  final working = GeneratedProject(
    directory: path.join(root, 'working'),
    sdk: c.sdk,
    python: 'python3',
    sources: await NativeGenerationHost.fingerprints(
      path.join(root, 'working'),
      source: true,
    ),
    confined: true,
    approval: approval,
    tasks: BuildPlan.parse(content, board: boards.load(project.id)).tasks,
  );
  await SourceGenerationStore(records).save(project.id, working);
  final sessions = AgentSessionStore(records, project);
  final selected = await sessions.create(
    c.sessionId,
    boards.load(project.id).tasks.map((t) => t.id).toList(),
  );
  await records.setString(
    selected.storageKey,
    const JsonEncoder.withIndent(' ').convert(selected.toJson()),
  );
  Future<ApprovedSourceProposal> suppliedProposal() async {
    final result =
        await ApprovedSourceProposer(
          records,
          proposer: SourceEditProposer(
            createProvider: (_) {
              counts['setupProviderCalls'] = counts['setupProviderCalls']! + 1;
              return _SuppliedInitialProvider();
            },
          ),
        ).propose(
          project: project,
          boardTaskId: 'Tanalyze',
          config: const LocalModelConfig(
            model: NativeInitialLineageChallenge.suppliedModel,
          ),
          originals: const {
            'lib/main.dart': _before,
            'lib/unchanged.dart': _unchanged,
          },
          sessionBinding: AgentSessionBinding.select(
            session: selected,
            projectId: project.id,
            boardTaskId: 'Tanalyze',
          ),
          requestWorkingRecord: records.getString(
            'studio.generation.v1.${project.id}',
          ),
          authorizeSession: () {},
        );
    counts['requestSetupCalls'] = counts['requestSetupCalls']! + 1;
    return result;
  }

  final evidence = await suppliedProposal();
  final later = await suppliedProposal();
  String proposal(ApprovedSourceProposal value) => jsonEncode({
    'summary': value.proposal.summary,
    'responseModel': value.proposal.responseModel,
    'changes': [
      for (final change in value.proposal.changes)
        {'path': change.path, 'before': change.before, 'after': change.after},
    ],
  });
  if (evidence.initialRequestOrigin?.reference.number != 1 ||
      later.initialRequestOrigin?.reference.number != 2 ||
      proposal(evidence) != proposal(later)) {
    throw StateError('Distinct supplied initial requests required.');
  }
  final prepared = GeneratedProject.fromJson({
    ...working.toJson(),
    'directory': path.join(root, 'candidate'),
    'sourceRequest': evidence.modelRequest!.toJson(),
    'sources': await NativeGenerationHost.fingerprints(
      path.join(root, 'candidate'),
      source: true,
    ),
  });
  return (working: working, prepared: prepared, evidence: evidence);
}

/// Called only after the parent fixture validates its bundle and private root.
/// Optional hold injection is for deterministic tests; challenge input cannot set it.
Future<void> runNativeInitialLineageFixture(
  String root,
  String rawChallenge, {
  Future<void> Function()? holdAfterReport,
}) async {
  final c = NativeInitialLineageChallenge.decode(rawChallenge);
  if (await Directory(c.sdk).resolveSymbolicLinks() != c.sdk) {
    throw StateError('Canonical existing fixture SDK required.');
  }
  final dbFile = File(path.join(root, 'initial-lineage.db'));
  if ((c.launch == 1) == await dbFile.exists()) {
    throw StateError('Unexpected fixture database stage.');
  }
  if (await FileSystemEntity.isLink(dbFile.path)) {
    throw StateError('Unsafe fixture database.');
  }
  // Isolate migration from preferences of any other fixture nonce.
  SharedPreferences.setPrefix('asg.nativeInitial.${c.nonce}.');
  final prefs = await SharedPreferences.getInstance();
  final db = await databaseFactoryIo.openDatabase(dbFile.path);
  try {
    var records = await StudioDatabase.migrate(db, prefs);
    final counts = {for (final key in _counterNames) key: 0};
    _Setup? supplied;
    final baselineFile = File(path.join(root, 'initial-lineage-baseline.json'));
    if (c.launch == 1) {
      supplied = await _setup(records, c, root, counts);
      await baselineFile.writeAsString(
        jsonEncode({
          'nonce': c.nonce,
          'workingSourceSha256': _mapHash(supplied.working.sources),
          'preparedSourceSha256': _mapHash(supplied.prepared.sources),
        }),
        flush: true,
      );
    }
    if (await FileSystemEntity.isLink(baselineFile.path) ||
        await baselineFile.length() > 4096) {
      throw StateError('Unsafe fixture baseline.');
    }
    final baselineRaw = await baselineFile.readAsString();
    rejectDuplicateJsonMembers(baselineRaw);
    final baseline = jsonDecode(baselineRaw) as Map<String, dynamic>;
    if (baseline.length != 3 || baseline['nonce'] != c.nonce) {
      throw StateError('Fixture baseline changed.');
    }
    final before = await _raw(db);
    final slots = _slots(c);
    if (c.corruptOptional) {
      await StoreRef<String, String>('records')
          .record(slots['companion1']!)
          .put(db, 'Supplied corrupt optional companion.');
      counts['corruptionControls'] = 1;
      records = await StudioDatabase.migrate(db, prefs);
    }
    Future<void> report() async {
      final after = await _raw(db);
      final view = await StudioDatabase.migrate(db, prefs);
      final session = AgentSessionStore(view, _project(c)).load(c.sessionId)!;
      final requests = SessionProposalRequestStore(
        view,
        c.projectId,
        c.sessionId,
      ).load().requests;
      final selected = requests.singleWhere((request) => request.number == 1);
      final latest = requests.singleWhere((request) => request.number == 2);
      final reference = SessionProposalRequestReference.fromRequest(selected);
      final latestReference = SessionProposalRequestReference.fromRequest(
        latest,
      );
      if (requests.length != 2 ||
          reference.requestSha256 == latestReference.requestSha256 ||
          _mapHash(selected.returnedSha256) !=
              _mapHash(latest.returnedSha256)) {
        throw StateError('Exact selected initial metadata unavailable.');
      }
      final journal = CandidateVerificationStore(view, c.projectId).load();
      final target = journal.runs
          .where((r) => r.number == c.targetRunNumber)
          .firstOrNull;
      final originalHash = selected.sessionSha256;
      var proofState = 'absent';
      String? durableAdmission;
      if (target != null) {
        try {
          final review = CandidateRequestLineageStore(
            view,
            c.projectId,
          ).load(target);
          if (review == null) throw StateError('Exact initial proof missing.');
          if (review.lineage.origin.reference.encode() != reference.encode()) {
            throw StateError('Wrong initial reference.');
          }
          if (c.launch == 4) {
            // Revalidate both retained companions in this independent process;
            // unchanged raw bytes alone are not a fresh historical join.
            final prior = journal.runs.singleWhere((run) => run.number == 1);
            final priorReview = CandidateRequestLineageStore(
              view,
              c.projectId,
            ).load(prior);
            if (priorReview == null ||
                priorReview.lineage.origin.reference.encode() !=
                    reference.encode() ||
                _hash(priorReview.lineage.admissionSessionRecord) !=
                    originalHash) {
              throw StateError('Retained original initial proof unavailable.');
            }
          }
          if (_hash(review.lineage.origin.requestSessionRecord) !=
              originalHash) {
            throw StateError('Original raw initial session changed.');
          }
          durableAdmission = _hash(review.lineage.admissionSessionRecord);
          proofState = 'joined';
        } catch (_) {
          if (!c.corruptOptional) rethrow;
          final statuses = AgentSessionRunStatusStore(
            view,
            c.projectId,
          ).load(session);
          if (!statuses.single.available ||
              statuses.single.initialLineage != null) {
            throw StateError('Core history lost isolation.');
          }
          proofState = 'unavailable';
        }
      }
      final captured = c.targetRunNumber == 1 ? originalHash : durableAdmission;
      if (captured == null) {
        throw StateError('Actual captured admission is unavailable.');
      }
      final value = <String, Object?>{
        'version': 23,
        'mode': NativeInitialLineageChallenge.mode,
        'nonce': c.nonce,
        'launch': c.launch,
        'boundary': c.boundary.name,
        'corruptOptional': c.corruptOptional,
        'stage': c.stage,
        'projectId': c.projectId,
        'sessionId': c.sessionId,
        'boardTaskId': 'Tanalyze',
        'requirementId': 'R1',
        'requestedModel': selected.modelRequest.model,
        'observedModel': selected.modelRequest.responseModel,
        'selectedRequestNumber': selected.number,
        'latestRequestNumber': latest.number,
        'requestCount': requests.length,
        'requestReference': reference.toJson(),
        'selectedRequestSha256': reference.requestSha256,
        'latestRequestSha256': latestReference.requestSha256,
        'selectedReturnedSourceSha256': _mapHash(selected.returnedSha256),
        'latestReturnedSourceSha256': _mapHash(latest.returnedSha256),
        'targetRunNumber': c.targetRunNumber,
        'targetDispatchId': c.targetDispatchId,
        'committedTargetRunNumber': target?.number,
        'committedTargetDispatchId': target?.dispatchId,
        'proofState': proofState,
        'originalRequestSessionSha256': originalHash,
        'capturedAdmissionSessionSha256': captured,
        'durableAdmissionSessionSha256': durableAdmission,
        'contextSha256': after[slots['context${c.targetRunNumber}']] == null
            ? null
            : _hash(after[slots['context${c.targetRunNumber}']]!),
        'companionSha256': after[slots['companion${c.targetRunNumber}']] == null
            ? null
            : _hash(after[slots['companion${c.targetRunNumber}']]!),
        'sessionRevision': session.revision,
        'sessionDispatchCount': session.dispatches.length,
        'recordsBefore': _slotHashes(before, c),
        'recordsAfter': _slotHashes(after, c),
        'unrelatedBeforeSha256': _unrelated(before, c),
        'unrelatedAfterSha256': _unrelated(after, c),
        'workingSourceSha256': baseline['workingSourceSha256'],
        'preparedSourceSha256': baseline['preparedSourceSha256'],
        'counters': counts,
      };
      final encoded = jsonEncode(value);
      if (utf8.encode(encoded).length > 8192) {
        throw StateError('Fixture report exceeds bound.');
      }
      await File(path.join(root, 'launch-${c.launch}.json'))
          .writeAsString(encoded, flush: true);
    }

    if (c.launch == 2 || c.launch == 4) {
      await report();
      return;
    }
    final barrier = _StartupPause(records, c, counts, () async {
      await report();
      if (holdAfterReport != null) {
        await holdAfterReport();
      } else {
        await Completer<void>().future;
      }
    });
    _InspectionHost host() {
      counts['hostCreations'] = counts['hostCreations']! + 1;
      return _InspectionHost(counts);
    }

    if (c.launch == 1) {
      final s = supplied!;
      final session = AgentSessionStore(
        barrier,
        _project(c),
      ).load(c.sessionId)!;
      final normalized = ApprovedSourceProposal(
        projectId: c.projectId,
        boardTaskId: 'Tanalyze',
        approval: s.evidence.approval,
        proposal: s.evidence.proposal,
        modelRequest: s.evidence.modelRequest,
        initialRequestOrigin: s.evidence.initialRequestOrigin,
      );
      final basis = CandidateReopenBasis.capture(
        projectId: c.projectId,
        workingRecord: records.getString(slots['working']!)!,
        working: s.working,
        sourceBase: s.working,
        prepared: s.prepared,
        evidence: normalized,
      );
      final controller = SourceCandidateController(
        project: _project(c),
        candidate: s.prepared,
        evidence: normalized,
        records: barrier,
        host: host(),
        publish: (_, _, _) async =>
            throw StateError('No publication supplied.'),
        sessionBinding: AgentSessionBinding.select(
          session: session,
          projectId: c.projectId,
          boardTaskId: 'Tanalyze',
        ),
        reopenBasis: basis,
      );
      counts['startupCalls'] = 1;
      await controller.verify(approved: true);
      counts['startupReturns'] = counts['startupReturns']! + 1;
      throw StateError('Initial startup pause unexpectedly returned.');
    } else {
      final session = AgentSessionStore(
        barrier,
        _project(c),
      ).load(c.sessionId)!;
      final recovery = SavedCandidateRecoveryController(
        project: _project(c),
        records: barrier,
        selectedSession: session,
        runNumber: 1,
        createHost: host,
      );
      await recovery.open();
      if (recovery.error != null ||
          recovery.candidate == null ||
          recovery.evidence?.initialRequestOrigin == null) {
        throw StateError('Production initial recovery unavailable.');
      }
      counts['startupCalls'] = 1;
      await recovery.candidate!.verify(approved: true);
      counts['startupReturns'] = counts['startupReturns']! + 1;
      throw StateError('Retry startup pause unexpectedly returned.');
    }
  } finally {
    await db.close();
  }
}

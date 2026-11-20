// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';

import 'package:asg/models/structured_proposal_json.dart';
import 'package:path/path.dart' as path;

import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/selected_repair_request.dart';
import 'package:asg/services/selected_repair_request_store.dart';

/// Fixed opt-in metadata. Parsing grants no storage or execution authority.
final class NativeRepairReturnChallenge {
  const NativeRepairReturnChallenge._(
    this.nonce,
    this.launch,
    this.sdk,
    this.boundary,
  );
  static const mode = 'repair-return-boundary';
  static const protocolVersion = 26;
  static const maxEncodedBytes = 4096;
  static const maxReportBytes = 8192;
  static const suppliedModel = 'supplied-native-repair-return-boundary-model';
  final String nonce, sdk, boundary;
  final int launch;
  bool get afterCommit => boundary == 'afterCommit';
  String get projectId => 'restart-$nonce';
  String get sessionId => 'session-$nonce';
  String get stage => launch == 1 ? 'held-terminal' : 'cold-retained';

  factory NativeRepairReturnChallenge.decode(String raw) {
    try {
      if (utf8.encode(raw).length > maxEncodedBytes) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      return NativeRepairReturnChallenge.fromJson(jsonDecode(raw));
    } catch (_) {
      throw const FormatException('Invalid native repair return challenge.');
    }
  }
  factory NativeRepairReturnChallenge.fromJson(Object? value) {
    const keys = {'mode', 'nonce', 'launch', 'sdk', 'boundary'};
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !keys.every(value.containsKey) ||
        value['mode'] != mode ||
        value['nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['nonce'] as String) ||
        value['launch'] is! int ||
        ![1, 2].contains(value['launch']) ||
        value['sdk'] is! String ||
        !['beforeCommit', 'afterCommit'].contains(value['boundary'])) {
      throw const FormatException('Invalid repair return challenge fields.');
    }
    final sdk = value['sdk'] as String;
    if (sdk.isEmpty ||
        sdk.contains(RegExp(r'[\x00\r\n]')) ||
        !path.posix.isAbsolute(sdk) ||
        path.posix.normalize(sdk) != sdk ||
        utf8.encode(jsonEncode(value)).length > maxEncodedBytes) {
      throw const FormatException('Invalid repair return challenge scope.');
    }
    return NativeRepairReturnChallenge._(
      value['nonce'] as String,
      value['launch'] as int,
      sdk,
      value['boundary'] as String,
    );
  }
  Map<String, Object> toJson() => {
    'mode': mode,
    'nonce': nonce,
    'launch': launch,
    'sdk': sdk,
    'boundary': boundary,
  };

  static const reportKeys = {
    'version',
    'mode',
    'nonce',
    'launch',
    'boundary',
    'stage',
    'projectId',
    'sessionId',
    'boardTaskId',
    'requirementId',
    'requestedModel',
    'attemptCount',
    'attemptNumber',
    'attemptStatus',
    'attemptSha256',
    'originSha256',
    'failureSha256',
    'originalSessionSha256',
    'sessionRevision',
    'sessionDispatchCount',
    'storedResponseModel',
    'storedProposalSha256',
    'validatedResponseModel',
    'validatedProposalSha256',
    'declaredSourceSha256',
    'deliveredReference',
    'retainedReference',
    'recordsBefore',
    'recordsAfter',
    'unrelatedBeforeSha256',
    'unrelatedAfterSha256',
    'counters',
  };

  static const counterKeys = {
    'setupCalls',
    'failureSetupCalls',
    'proposalCalls',
    'reservationCommits',
    'reservationReturns',
    'suppliedProviderCalls',
    'proposalReturns',
    'terminalAttempts',
    'terminalCommits',
    'terminalReturns',
    'liveTransportAttempts',
    'sdkAttempts',
    'candidateEffects',
    'unrelatedWrites',
    'previewAttempts',
    'sourceCopies',
    'hostCreations',
  };

  Map<String, String> get recordSlots => {
    'working': 'studio.generation.v1.$projectId',
    'repairOrigin': 'studio.selectedRepairRequest.v1.$projectId.1',
    'repairJournal': 'studio.repairAttempts.v1.$projectId',
    'failureJournal': 'studio.candidateChecks.v1.$projectId',
    'failedCandidate': 'studio.sourceCandidate.v1.$projectId',
    'session': 'studio.agentSession.v1.$projectId.$sessionId',
    'execution': 'studio.agentExecution.v1.candidate-$projectId-2',
    'history': 'studio.agentTaskHistory.v1.$projectId.2',
    'context': 'studio.candidateReopen.v1.$projectId.2',
    'initialCompanion': 'studio.candidateRequestLineage.v1.$projectId.2',
    'repairCompanion': 'studio.candidateRepairLineage.v1.$projectId.2',
  };
}

StudioProject _project(NativeRepairReturnChallenge c) => StudioProject(
  id: c.projectId,
  name: 'Supplied repair terminal metadata',
  description: 'Fixed metadata only',
  type: 'Flutter',
  platforms: const ['Web'],
  location: '',
);

Future<GeneratedProject> _seed(
  StudioDatabase records,
  NativeRepairReturnChallenge c,
  String root,
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
        acceptance: 'Inspect exact repair request lineage',
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
  final working = GeneratedProject(
    directory: path.join(root, 'working'),
    sdk: c.sdk,
    python: 'python3',
    sources: {...input.fingerprints, 'lib/main.dart': _hash(_before)},
    confined: true,
    approval: approval,
    tasks: BuildPlan.parse(content, board: boards.load(project.id)).tasks,
  );
  await SourceGenerationStore(records).save(project.id, working);
  final failed = working.copy(
    phase: SourceGenerationPhase.failed,
    checkpointVersion: 1,
    steps: const [
      GenerationStep(
        operation: 'resolve',
        exitCode: 0,
        output: 'Supplied; no SDK ran.',
      ),
      GenerationStep(
        operation: 'test',
        exitCode: 0,
        output: 'Supplied; no SDK ran.',
      ),
      GenerationStep(
        operation: 'analyze',
        exitCode: 1,
        output: 'Supplied diagnostic; no SDK ran.',
      ),
    ],
  );
  final failure = CandidateVerificationRun(
    number: 1,
    startedAt: DateTime.utc(2026),
    snapshot: failed,
    finished: true,
  );
  await records.setString(
    'studio.candidateChecks.v1.${project.id}',
    jsonEncode(CandidateVerificationJournal([failure]).toJson()),
  );
  await records.setString(
    'studio.sourceCandidate.v1.${project.id}',
    jsonEncode(failed.toJson()),
  );
  final session = await AgentSessionStore(records, project).create(
    c.sessionId,
    boards.load(project.id).tasks.map((t) => t.id).toList(),
  );
  await records.setString(
    session.storageKey,
    const JsonEncoder.withIndent(' ').convert(session.toJson()),
  );
  return failed;
}

String _hash(String text) => sha256.convert(utf8.encode(text)).toString();
String _mapHash(Map<String, String> values) => _hash(
  jsonEncode({
    for (final key in values.keys.toList()..sort()) key: values[key],
  }),
);
const _before = 'void main() {}';
const _after = 'void main() { /* supplied repair terminal fixture return */ }';

Future<Map<String, String>> _raw(Database database) async => {
  for (final row in await StoreRef<String, String>('records').find(database))
    row.key: row.value,
};
void _same(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length || a.entries.any((e) => b[e.key] != e.value)) {
    throw StateError('Terminal fixture physical records changed.');
  }
}

Map<String, String?> _slots(
  Map<String, String> raw,
  NativeRepairReturnChallenge c,
) => {
  for (final e in c.recordSlots.entries)
    e.key: raw[e.value] == null ? null : _hash(raw[e.value]!),
};
String _unrelated(Map<String, String> raw, NativeRepairReturnChallenge c) =>
    _mapHash({
      for (final e in raw.entries)
        if (!c.recordSlots.values.contains(e.key)) e.key: e.value,
    });

class _SuppliedProvider
    implements ModelProvider, ModelResponseIdentityProvider {
  bool _entered = false;
  @override
  String get completedResponseModel =>
      NativeRepairReturnChallenge.suppliedModel;
  @override
  Stream<String> generate(String prompt) {
    if (_entered) throw StateError('Supplied provider may enter once only.');
    _entered = true;
    return Stream.value(
      jsonEncode({
        'summary': 'Fixed supplied terminal return',
        'changes': [
          {'path': 'lib/main.dart', 'before': _before, 'after': _after},
        ],
      }),
    );
  }

  @override
  Future<void> cancel() async {}
}

String _proposalHash(RepairAttempt attempt) =>
    _hash(jsonEncode(attempt.toJson()['proposal']));
String _expectedProposalHash() => _hash(
  jsonEncode({
    'summary': 'Fixed supplied terminal return',
    'changes': [
      {'path': 'lib/main.dart', 'before': _before, 'after': _after},
    ],
  }),
);

class _RepairRecords implements ConditionalRecordStorage {
  _RepairRecords(
    this.delegate,
    this.database,
    this.c,
    this.counts,
    this.report,
  );
  final StudioDatabase delegate;
  final Database database;
  final NativeRepairReturnChallenge c;
  final Map<String, int> counts;
  final Future<void> Function() report;
  String? _originRaw;
  @override
  String? getString(String key) => delegate.getString(key);
  Never _refuse() {
    counts['unrelatedWrites'] = counts['unrelatedWrites']! + 1;
    throw StateError('No other repair terminal fixture write is authorized.');
  }

  @override
  Future<bool> setString(String key, String value) async => _refuse();
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    final key = c.recordSlots['repairJournal']!,
        originKey = c.recordSlots['repairOrigin']!;
    if (c.launch != 1 || !updates.containsKey(key)) _refuse();
    final next = RepairAttemptJournal.fromJson(
      jsonDecode(updates[key]!) as Map<String, dynamic>,
    );
    if (next.attempts.length != 1 || next.attempts.single.number != 1) {
      _refuse();
    }
    final attempt = next.attempts.single;
    final reserve = attempt.status == RepairAttemptStatus.reserved;
    if (reserve) {
      if (updates.length != 2 ||
          !updates.containsKey(originKey) ||
          counts['reservationCommits'] != 0 ||
          delegate.getString(key) != null ||
          delegate.getString(originKey) != null) {
        _refuse();
      }
      SelectedRepairRequest.decode(updates[originKey]!).requireAttempt(attempt);
    } else {
      if (updates.length != 1 ||
          attempt.status != RepairAttemptStatus.proposed ||
          counts['reservationReturns'] != 1 ||
          counts['terminalAttempts'] != 0 ||
          counts['suppliedProviderCalls'] != 1 ||
          _originRaw == null ||
          delegate.getString(originKey) != _originRaw ||
          attempt.modelRequest?.responseModel !=
              NativeRepairReturnChallenge.suppliedModel ||
          attempt.proposal == null ||
          _proposalHash(attempt) != _expectedProposalHash()) {
        _refuse();
      }
      SelectedRepairRequest.decode(_originRaw!).requireAttempt(attempt);
      counts['terminalAttempts'] = 1;
      if (!c.afterCommit) await report();
    }
    await delegate.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
    for (final e in updates.entries) {
      if (await StoreRef<String, String>('records')
              .record(e.key)
              .get(database) !=
          e.value) {
        throw StateError('Actual native repair terminal commit required.');
      }
    }
    if (reserve) {
      _originRaw = delegate.getString(originKey);
      counts['reservationCommits'] = 1;
      counts['reservationReturns'] = 1;
    } else {
      counts['terminalCommits'] = 1;
      await report();
      counts['terminalReturns'] = 1;
      throw StateError('Repair terminal fixture pause must not return.');
    }
  }
}

Future<void> _capture(
  String root,
  NativeRepairReturnChallenge c,
  Map<String, String> records,
) async {
  final file = File(path.join(root, 'capture-1.json'));
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('Fresh private repair capture required.');
  }
  final raw = jsonEncode({
    'nonce': c.nonce,
    'boundary': c.boundary,
    'records': records,
  });
  if (utf8.encode(raw).length > 131072) {
    throw StateError('Repair capture exceeds bound.');
  }
  await file.writeAsString(raw, flush: true);
}

Future<Map<String, String>> _readCapture(
  String root,
  NativeRepairReturnChallenge c,
) async {
  final file = File(path.join(root, 'capture-1.json'));
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await file.length() > 131072) {
    throw StateError('Invalid private repair capture.');
  }
  final raw = await file.readAsString();
  rejectDuplicateJsonMembers(raw);
  final value = jsonDecode(raw);
  if (value is! Map<String, dynamic> ||
      value.length != 3 ||
      value['nonce'] != c.nonce ||
      value['boundary'] != c.boundary ||
      value['records'] is! Map<String, dynamic>) {
    throw StateError('Repair capture identity changed.');
  }
  final records = value['records'] as Map<String, dynamic>;
  if (records.length > 128 || records.values.any((v) => v is! String)) {
    throw StateError('Invalid repair capture records.');
  }
  return records.cast<String, String>();
}

/// Fixed opt-in native fixture. A supplied VM hold release is not a process crash.
Future<void> runNativeRepairReturnBoundaryFixture(
  String root,
  String rawChallenge, {
  Future<void> Function()? holdAfterReport,
}) async {
  final c = NativeRepairReturnChallenge.decode(rawChallenge),
      directory = Directory(root);
  if (await directory.resolveSymbolicLinks() != root ||
      !path.isWithin(await Directory.systemTemp.resolveSymbolicLinks(), root) ||
      !path.basename(root).startsWith('asg-candidate-crash-') ||
      (await directory.stat()).mode & 0x3f != 0 ||
      await Directory(c.sdk).resolveSymbolicLinks() != c.sdk) {
    throw StateError(
      'Private canonical fixture root and existing SDK required.',
    );
  }
  final file = File(path.join(root, 'repair-return-boundary.db'));
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      (c.launch == 1
          ? FileSystemEntityType.notFound
          : FileSystemEntityType.file)) {
    throw StateError('Unexpected native repair terminal database stage.');
  }
  SharedPreferences.setPrefix('asg.nativeRepairReturn.${c.nonce}.');
  final preferences = await SharedPreferences.getInstance(),
      database = await databaseFactoryIo.openDatabase(file.path);
  ApprovedSourceProposer? service;
  try {
    final opened = await _raw(database),
        records = await StudioDatabase.migrate(database, preferences);
    if (c.launch == 2) _same(opened, await _raw(database));
    final counts = {
      for (final k in NativeRepairReturnChallenge.counterKeys) k: 0,
    };
    final project = _project(c);
    GeneratedProject? failed;
    if (c.launch == 1) {
      failed = await _seed(records, c, root);
      counts['setupCalls'] = 1;
      counts['failureSetupCalls'] = 1;
    }
    final before = await _raw(database);
    if (c.launch == 2) _same(before, await _readCapture(root, c));
    Future<void> report() async {
      final after = await _raw(database),
          key = c.recordSlots['repairJournal']!,
          originKey = c.recordSlots['repairOrigin']!;
      final journal = RepairAttemptJournal.fromJson(
        jsonDecode(after[key]!) as Map<String, dynamic>,
      );
      if (journal.attempts.length != 1) {
        throw StateError('Exactly one repair terminal attempt required.');
      }
      final attempt = journal.attempts.single, originRaw = after[originKey]!;
      final origin = SelectedRepairRequest.decode(originRaw);
      origin.requireAttempt(attempt);
      final failure = CandidateVerificationJournal.fromJson(
        jsonDecode(after[c.recordSlots['failureJournal']]!)
            as Map<String, dynamic>,
      ).runs.single;
      final stored = c.afterCommit, expectedHash = _expectedProposalHash();
      if (attempt.number != 1 ||
          attempt.status !=
              (stored
                  ? RepairAttemptStatus.proposed
                  : RepairAttemptStatus.reserved) ||
          attempt.modelRequest?.model !=
              NativeRepairReturnChallenge.suppliedModel ||
          attempt.modelRequest?.responseModel !=
              (stored ? NativeRepairReturnChallenge.suppliedModel : null) ||
          (stored
              ? (attempt.proposal == null ||
                    _proposalHash(attempt) != expectedHash)
              : attempt.proposal != null) ||
          jsonEncode(attempt.failure.toJson()) !=
              jsonEncode(failure.toJson()) ||
          jsonEncode(failure.snapshot.toJson()) !=
              after[c.recordSlots['failedCandidate']]) {
        throw StateError(
          'Physical repair terminal outcome or failure changed.',
        );
      }
      final sessionRaw = after[c.recordSlots['session']]!,
          session = AgentSession.fromJson(jsonDecode(sessionRaw));
      if (session.revision != 0 ||
          session.dispatches.isNotEmpty ||
          origin.requestSessionRecord != sessionRaw ||
          origin.workingSha256 != _hash(after[c.recordSlots['working']]!)) {
        throw StateError(
          'Original selected repair session or working record changed.',
        );
      }
      final expected = {
        for (final k in NativeRepairReturnChallenge.counterKeys) k: 0,
      };
      if (c.launch == 1) {
        for (final k in [
          'setupCalls',
          'failureSetupCalls',
          'proposalCalls',
          'reservationCommits',
          'reservationReturns',
          'suppliedProviderCalls',
          'terminalAttempts',
        ]) {
          expected[k] = 1;
        }
        expected['terminalCommits'] = stored ? 1 : 0;
      }
      if (counts.entries.any((e) => expected[e.key] != e.value)) {
        throw StateError('Unexpected repair terminal fixture effects.');
      }
      final b = _slots(before, c), a = _slots(after, c);
      for (final slot in [
        'execution',
        'history',
        'context',
        'initialCompanion',
        'repairCompanion',
      ]) {
        if (b[slot] != null || a[slot] != null) {
          throw StateError('Unexpected repair execution or companion record.');
        }
      }
      for (final slot in [
        'working',
        'failureJournal',
        'failedCandidate',
        'session',
      ]) {
        if (b[slot] == null || b[slot] != a[slot]) {
          throw StateError('Retained repair basis changed.');
        }
      }
      if (_unrelated(before, c) != _unrelated(after, c)) {
        throw StateError('Unrelated repair terminal records changed.');
      }
      if (c.launch == 2) _same(before, after);
      final working = GeneratedProject.fromJson(
        jsonDecode(after[c.recordSlots['working']]!),
      );
      final value = <String, Object?>{
        'version': 26,
        'mode': NativeRepairReturnChallenge.mode,
        'nonce': c.nonce,
        'launch': c.launch,
        'boundary': c.boundary,
        'stage': c.stage,
        'projectId': c.projectId,
        'sessionId': c.sessionId,
        'boardTaskId': 'Tanalyze',
        'requirementId': 'R1',
        'requestedModel': NativeRepairReturnChallenge.suppliedModel,
        'attemptCount': 1,
        'attemptNumber': 1,
        'attemptStatus': attempt.status.name,
        'attemptSha256': _hash(jsonEncode(attempt.toJson())),
        'originSha256': _hash(originRaw),
        'failureSha256': _hash(jsonEncode(failure.toJson())),
        'originalSessionSha256': _hash(sessionRaw),
        'sessionRevision': session.revision,
        'sessionDispatchCount': session.dispatches.length,
        'storedResponseModel': attempt.modelRequest?.responseModel,
        'storedProposalSha256': stored ? _proposalHash(attempt) : null,
        'validatedResponseModel': c.launch == 1
            ? NativeRepairReturnChallenge.suppliedModel
            : null,
        'validatedProposalSha256': c.launch == 1 ? expectedHash : null,
        'declaredSourceSha256': _mapHash(working.sources),
        'deliveredReference': null,
        'retainedReference': c.launch == 2 && stored
            ? SelectedRepairRequestReference.forProposed(
                origin,
                attempt,
              ).toJson()
            : null,
        'recordsBefore': b,
        'recordsAfter': a,
        'unrelatedBeforeSha256': _unrelated(before, c),
        'unrelatedAfterSha256': _unrelated(after, c),
        'counters': counts,
      };
      if (value.length != NativeRepairReturnChallenge.reportKeys.length ||
          !NativeRepairReturnChallenge.reportKeys.every(value.containsKey)) {
        throw StateError('Repair terminal report schema drift.');
      }
      final encoded = jsonEncode(value);
      if (utf8.encode(encoded).length >
          NativeRepairReturnChallenge.maxReportBytes) {
        throw StateError('Repair report exceeds bound.');
      }
      final output = File(path.join(root, 'launch-${c.launch}.json'));
      if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Fresh repair report required.');
      }
      if (c.launch == 1) await _capture(root, c, after);
      await output.writeAsString(encoded, flush: true);
      if (c.launch == 1) {
        if (holdAfterReport != null) {
          await holdAfterReport();
        } else {
          await Completer<void>().future;
        }
        throw StateError('Repair terminal fixture pause must not return.');
      }
    }

    final guarded = _RepairRecords(records, database, c, counts, report);
    if (c.launch == 2) {
      final page = SelectedRepairRequestStore(
        guarded,
        c.projectId,
      ).load(c.sessionId);
      if (page.entries.length != 1 || page.entries.single.origin == null) {
        throw StateError('Selected repair cold origin missing.');
      }
      await report();
      return;
    }
    final session = AgentSessionStore(guarded, project).load(c.sessionId)!;
    service = ApprovedSourceProposer(
      guarded,
      proposer: SourceEditProposer(
        createProvider: (_) {
          counts['suppliedProviderCalls'] =
              counts['suppliedProviderCalls']! + 1;
          return _SuppliedProvider();
        },
      ),
    );
    counts['proposalCalls'] = 1;
    await service.propose(
      project: project,
      boardTaskId: 'Tanalyze',
      config: const LocalModelConfig(
        model: NativeRepairReturnChallenge.suppliedModel,
      ),
      originals: const {'lib/main.dart': _before},
      repairCandidate: failed!,
      repairSessionBinding: AgentSessionBinding.select(
        session: session,
        projectId: c.projectId,
        boardTaskId: 'Tanalyze',
      ),
      repairWorkingRecord: guarded.getString(c.recordSlots['working']!),
    );
    counts['proposalReturns'] = 1;
    throw StateError('Repair terminal proposal must not return.');
  } finally {
    try {
      await service?.cancel();
    } finally {
      await database.close();
    }
  }
}

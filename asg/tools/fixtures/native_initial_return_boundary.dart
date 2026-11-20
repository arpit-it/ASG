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
import 'package:asg/models/session_proposal_request.dart';
import 'package:asg/models/session_proposal_reference.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/session_proposal_request_store.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';

import 'package:asg/models/structured_proposal_json.dart';
import 'package:path/path.dart' as path;

/// Fixed opt-in metadata. Parsing grants no storage or execution authority.
final class NativeInitialReturnChallenge {
  const NativeInitialReturnChallenge._(
    this.nonce,
    this.launch,
    this.sdk,
    this.boundary,
  );
  static const mode = 'initial-return-boundary';
  static const protocolVersion = 25;
  static const maxEncodedBytes = 4096;
  static const maxReportBytes = 8192;
  static const suppliedModel = 'supplied-native-initial-return-boundary-model';
  final String nonce, sdk, boundary;
  final int launch;
  bool get afterCommit => boundary == 'afterCommit';
  String get projectId => 'restart-$nonce';
  String get sessionId => 'session-$nonce';
  String get stage => launch == 1 ? 'held-terminal' : 'cold-retained';

  factory NativeInitialReturnChallenge.decode(String raw) {
    try {
      if (utf8.encode(raw).length > maxEncodedBytes) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      return NativeInitialReturnChallenge.fromJson(jsonDecode(raw));
    } catch (_) {
      throw const FormatException('Invalid native initial return challenge.');
    }
  }
  factory NativeInitialReturnChallenge.fromJson(Object? value) {
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
      throw const FormatException('Invalid initial return challenge fields.');
    }
    final sdk = value['sdk'] as String;
    if (sdk.isEmpty ||
        sdk.contains(RegExp(r'[\x00\r\n]')) ||
        !path.posix.isAbsolute(sdk) ||
        path.posix.normalize(sdk) != sdk ||
        utf8.encode(jsonEncode(value)).length > maxEncodedBytes) {
      throw const FormatException('Invalid initial return challenge scope.');
    }
    return NativeInitialReturnChallenge._(
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
    'requestCount',
    'requestNumber',
    'requestStatus',
    'requestSha256',
    'storedResponseModel',
    'storedReturnedSourceSha256',
    'validatedResponseModel',
    'validatedReturnedSourceSha256',
    'originalSessionSha256',
    'sessionRevision',
    'sessionDispatchCount',
    'deliveredReference',
    'retainedReference',
    'recordsBefore',
    'recordsAfter',
    'unrelatedBeforeSha256',
    'unrelatedAfterSha256',
    'declaredSourceSha256',
    'counters',
  };

  static const counterKeys = {
    'setupCalls',
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
    'requestJournal': 'studio.sessionProposalRequests.v1.$projectId.$sessionId',
    'session': 'studio.agentSession.v1.$projectId.$sessionId',
    'candidateJournal': 'studio.candidateChecks.v1.$projectId',
    'candidate': 'studio.sourceCandidate.v1.$projectId',
    'execution': 'studio.agentExecution.v1.candidate-$projectId-1',
    'history': 'studio.agentTaskHistory.v1.$projectId.1',
    'context': 'studio.candidateReopen.v1.$projectId.1',
    'initialCompanion': 'studio.candidateRequestLineage.v1.$projectId.1',
    'repairCompanion': 'studio.candidateRepairLineage.v1.$projectId.1',
  };
}

StudioProject _project(NativeInitialReturnChallenge c) => StudioProject(
  id: c.projectId,
  name: 'Supplied initial terminal metadata',
  description: 'Fixed metadata only',
  type: 'Flutter',
  platforms: const ['Web'],
  location: '',
);

Future<void> _seed(
  StudioDatabase records,
  NativeInitialReturnChallenge c,
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

  final working = GeneratedProject(
    directory: path.join(root, 'working'),
    sdk: c.sdk,
    python: 'python3',
    sources: {'lib/main.dart': _hash(_before)},
    confined: true,
    approval: approval,
    tasks: BuildPlan.parse(content, board: boards.load(project.id)).tasks,
  );
  await SourceGenerationStore(records).save(project.id, working);
  final session = await AgentSessionStore(records, project).create(
    c.sessionId,
    boards.load(project.id).tasks.map((t) => t.id).toList(),
  );
  await records.setString(
    session.storageKey,
    const JsonEncoder.withIndent(' ').convert(session.toJson()),
  );
}

String _hash(String text) => sha256.convert(utf8.encode(text)).toString();
String _mapHash(Map<String, String> values) => _hash(
  jsonEncode({
    for (final key in values.keys.toList()..sort()) key: values[key],
  }),
);
const _before = 'void main() {}';
const _after = 'void main() { /* supplied initial terminal fixture return */ }';

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
  NativeInitialReturnChallenge c,
) => {
  for (final e in c.recordSlots.entries)
    e.key: raw[e.value] == null ? null : _hash(raw[e.value]!),
};
String _unrelated(Map<String, String> raw, NativeInitialReturnChallenge c) =>
    _mapHash({
      for (final e in raw.entries)
        if (!c.recordSlots.values.contains(e.key)) e.key: e.value,
    });

class _SuppliedProvider
    implements ModelProvider, ModelResponseIdentityProvider {
  bool _entered = false;
  @override
  String get completedResponseModel =>
      NativeInitialReturnChallenge.suppliedModel;
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

class _TerminalRecords implements ConditionalRecordStorage {
  _TerminalRecords(
    this.delegate,
    this.database,
    this.c,
    this.counts,
    this.report,
  );
  final StudioDatabase delegate;
  final Database database;
  final NativeInitialReturnChallenge c;
  final Map<String, int> counts;
  final Future<void> Function() report;
  @override
  String? getString(String key) => delegate.getString(key);
  Never _refuse() {
    counts['unrelatedWrites'] = counts['unrelatedWrites']! + 1;
    throw StateError('No other terminal fixture write is authorized.');
  }

  @override
  Future<bool> setString(String key, String value) async => _refuse();
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    final key = c.recordSlots['requestJournal']!;
    if (c.launch != 1 || updates.length != 1 || !updates.containsKey(key)) {
      _refuse();
    }
    final next = SessionProposalRequestJournal.decode(updates[key]!);
    if (next.requests.length != 1 || next.requests.single.number != 1) {
      _refuse();
    }
    final request = next.requests.single;
    final reserve = request.status == SessionProposalRequestStatus.reserved;
    if (reserve) {
      if (counts['reservationCommits'] != 0 ||
          delegate.getString(key) != null) {
        _refuse();
      }
    } else {
      if (request.status != SessionProposalRequestStatus.returnedValidated ||
          counts['reservationReturns'] != 1 ||
          counts['terminalAttempts'] != 0 ||
          counts['suppliedProviderCalls'] != 1 ||
          request.modelRequest.responseModel !=
              NativeInitialReturnChallenge.suppliedModel ||
          _mapHash(request.returnedSha256) !=
              _mapHash({'lib/main.dart': _hash(_after)})) {
        _refuse();
      }
      counts['terminalAttempts'] = 1;
      if (!c.afterCommit) await report();
    }
    await delegate.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
    if (await StoreRef<String, String>('records').record(key).get(database) !=
        updates[key]) {
      throw StateError('Actual native terminal fixture commit required.');
    }
    if (reserve) {
      counts['reservationCommits'] = 1;
      counts['reservationReturns'] = 1;
    } else {
      counts['terminalCommits'] = 1;
      await report();
      counts['terminalReturns'] = 1;
      throw StateError('Terminal fixture pause must not return.');
    }
  }
}

Future<void> _writeCapture(
  String root,
  NativeInitialReturnChallenge c,
  Map<String, String> records,
) async {
  final file = File(path.join(root, 'capture-1.json'));
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('Fresh private capture required.');
  }
  final raw = jsonEncode({
    'nonce': c.nonce,
    'boundary': c.boundary,
    'records': records,
  });
  if (utf8.encode(raw).length > 131072) {
    throw StateError('Capture exceeds bound.');
  }
  await file.writeAsString(raw, flush: true);
}

Future<Map<String, String>> _readCapture(
  String root,
  NativeInitialReturnChallenge c,
) async {
  final file = File(path.join(root, 'capture-1.json'));
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await file.length() > 131072) {
    throw StateError('Invalid private capture.');
  }
  final raw = await file.readAsString();
  rejectDuplicateJsonMembers(raw);
  final value = jsonDecode(raw);
  if (value is! Map<String, dynamic> ||
      value.length != 3 ||
      value['nonce'] != c.nonce ||
      value['boundary'] != c.boundary ||
      value['records'] is! Map<String, dynamic>) {
    throw StateError('Capture identity changed.');
  }
  final records = value['records'] as Map<String, dynamic>;
  if (records.length > 128 || records.values.any((v) => v is! String)) {
    throw StateError('Invalid capture records.');
  }
  return records.cast<String, String>();
}

/// Fixed disposable process fixture. VM release is not native crash evidence.
Future<void> runNativeInitialReturnBoundaryFixture(
  String root,
  String rawChallenge, {
  Future<void> Function()? holdAfterReport,
}) async {
  final c = NativeInitialReturnChallenge.decode(rawChallenge);
  final directory = Directory(root);
  if (await directory.resolveSymbolicLinks() != root ||
      !path.isWithin(await Directory.systemTemp.resolveSymbolicLinks(), root) ||
      !path.basename(root).startsWith('asg-candidate-crash-') ||
      (await directory.stat()).mode & 0x3f != 0 ||
      await Directory(c.sdk).resolveSymbolicLinks() != c.sdk) {
    throw StateError(
      'Private canonical fixture root and existing SDK required.',
    );
  }
  final file = File(path.join(root, 'initial-return-boundary.db'));
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type !=
      (c.launch == 1
          ? FileSystemEntityType.notFound
          : FileSystemEntityType.file)) {
    throw StateError('Unexpected native terminal database stage.');
  }
  SharedPreferences.setPrefix('asg.nativeInitialReturn.${c.nonce}.');
  final preferences = await SharedPreferences.getInstance();
  final database = await databaseFactoryIo.openDatabase(file.path);
  ApprovedSourceProposer? service;
  try {
    final opened = await _raw(database);
    final records = await StudioDatabase.migrate(database, preferences);
    if (c.launch == 2) _same(opened, await _raw(database));
    final counts = {
      for (final key in NativeInitialReturnChallenge.counterKeys) key: 0,
    };
    final project = _project(c);
    if (c.launch == 1) {
      await _seed(records, c, root);
      counts['setupCalls'] = 1;
    }
    final before = await _raw(database);
    if (c.launch == 2) _same(before, await _readCapture(root, c));
    Future<void> report() async {
      final after = await _raw(database),
          key = c.recordSlots['requestJournal']!;
      final journal = SessionProposalRequestJournal.decode(after[key]!);
      if (journal.requests.length != 1) {
        throw StateError('Exactly one terminal request required.');
      }
      final request = journal.requests.single;
      final stored = c.afterCommit;
      final returnedHashes = {'lib/main.dart': _hash(_after)};
      if (request.number != 1 ||
          request.status !=
              (stored
                  ? SessionProposalRequestStatus.returnedValidated
                  : SessionProposalRequestStatus.reserved) ||
          request.modelRequest.model !=
              NativeInitialReturnChallenge.suppliedModel ||
          request.modelRequest.responseModel !=
              (stored ? NativeInitialReturnChallenge.suppliedModel : null) ||
          (stored
              ? _mapHash(request.returnedSha256) != _mapHash(returnedHashes)
              : request.returnedSha256.isNotEmpty)) {
        throw StateError('Physical terminal request outcome changed.');
      }
      final sessionRaw = after[c.recordSlots['session']]!;
      final session = AgentSession.fromJson(jsonDecode(sessionRaw));
      final working = GeneratedProject.fromJson(
        jsonDecode(after[c.recordSlots['working']]!),
      );
      if (session.revision != 0 ||
          session.dispatches.isNotEmpty ||
          request.sessionSha256 != _hash(sessionRaw)) {
        throw StateError('Original selected session changed.');
      }
      final expected = {
        for (final k in NativeInitialReturnChallenge.counterKeys) k: 0,
      };
      if (c.launch == 1) {
        for (final k in [
          'setupCalls',
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
        throw StateError('Unexpected terminal fixture effects.');
      }
      final bs = _slots(before, c), a = _slots(after, c);
      for (final slot in c.recordSlots.keys.where(
        (k) => !['working', 'requestJournal', 'session'].contains(k),
      )) {
        if (bs[slot] != null || a[slot] != null) {
          throw StateError('Unexpected candidate or execution record.');
        }
      }
      if (_unrelated(before, c) != _unrelated(after, c) ||
          bs['working'] != a['working'] ||
          bs['session'] != a['session']) {
        throw StateError('Unrelated terminal records changed.');
      }
      if (c.launch == 2) _same(before, after);
      final value = <String, Object?>{
        'version': 25,
        'mode': NativeInitialReturnChallenge.mode,
        'nonce': c.nonce,
        'launch': c.launch,
        'boundary': c.boundary,
        'stage': c.stage,
        'projectId': c.projectId,
        'sessionId': c.sessionId,
        'boardTaskId': 'Tanalyze',
        'requirementId': 'R1',
        'requestedModel': NativeInitialReturnChallenge.suppliedModel,
        'requestCount': 1,
        'requestNumber': 1,
        'requestStatus': request.status.name,
        'requestSha256': _hash(jsonEncode(request.toJson())),
        'storedResponseModel': request.modelRequest.responseModel,
        'storedReturnedSourceSha256': stored
            ? _mapHash(request.returnedSha256)
            : null,
        'validatedResponseModel': c.launch == 1
            ? NativeInitialReturnChallenge.suppliedModel
            : null,
        'validatedReturnedSourceSha256': c.launch == 1
            ? _mapHash(returnedHashes)
            : null,
        'originalSessionSha256': _hash(sessionRaw),
        'sessionRevision': session.revision,
        'sessionDispatchCount': session.dispatches.length,
        'deliveredReference': null,
        'retainedReference': c.launch == 2 && stored
            ? SessionProposalRequestReference.fromRequest(request).toJson()
            : null,
        'recordsBefore': bs,
        'recordsAfter': a,
        'unrelatedBeforeSha256': _unrelated(before, c),
        'unrelatedAfterSha256': _unrelated(after, c),
        'declaredSourceSha256': _mapHash(working.sources),
        'counters': counts,
      };
      if (value.length != NativeInitialReturnChallenge.reportKeys.length ||
          !NativeInitialReturnChallenge.reportKeys.every(value.containsKey)) {
        throw StateError('Terminal report schema drift.');
      }
      final encoded = jsonEncode(value);
      if (utf8.encode(encoded).length >
          NativeInitialReturnChallenge.maxReportBytes) {
        throw StateError('Terminal report exceeds bound.');
      }
      final output = File(path.join(root, 'launch-${c.launch}.json'));
      if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Fresh terminal report required.');
      }
      if (c.launch == 1) await _writeCapture(root, c, after);
      await output.writeAsString(encoded, flush: true);
      if (c.launch == 1) {
        if (holdAfterReport != null) {
          await holdAfterReport();
        } else {
          await Completer<void>().future;
        }
        throw StateError('Terminal fixture pause must not return.');
      }
    }

    final guarded = _TerminalRecords(records, database, c, counts, report);
    if (c.launch == 2) {
      SessionProposalRequestStore(guarded, c.projectId, c.sessionId).load();
      AgentSessionStore(guarded, project).load(c.sessionId);
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
        model: NativeInitialReturnChallenge.suppliedModel,
      ),
      originals: const {'lib/main.dart': _before},
      sessionBinding: AgentSessionBinding.select(
        session: session,
        projectId: c.projectId,
        boardTaskId: 'Tanalyze',
      ),
      requestWorkingRecord: guarded.getString(c.recordSlots['working']!),
      authorizeSession: () {},
    );
    counts['proposalReturns'] = 1;
    throw StateError('Initial terminal fixture proposal must not return.');
  } finally {
    try {
      await service?.cancel();
    } finally {
      await database.close();
    }
  }
}

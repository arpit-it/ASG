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

/// Fixed opt-in fixture metadata only. Parsing grants no storage/tool authority.
final class NativeInitialUnresolvedChallenge {
  const NativeInitialUnresolvedChallenge._({
    required this.nonce,
    required this.launch,
    required this.sdk,
    required this.explicitNext,
  });

  static const mode = 'initial-unresolved';
  static const protocolVersion = 24;
  static const maxEncodedBytes = 4096;
  static const maxReportBytes = 8192;
  static const suppliedModel = 'supplied-native-initial-unresolved-model';
  final String nonce, sdk;
  final int launch;
  final bool explicitNext;

  String get projectId => 'restart-$nonce';
  String get sessionId => 'session-$nonce';
  String get stage => switch (launch) {
    1 => 'reserved-paused',
    2 => 'read-only',
    3 => 'fresh-return-paused',
    _ => 'fresh-read-only',
  };

  factory NativeInitialUnresolvedChallenge.decode(String raw) {
    try {
      if (utf8.encode(raw).length > maxEncodedBytes) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      return NativeInitialUnresolvedChallenge.fromJson(jsonDecode(raw));
    } catch (_) {
      throw const FormatException(
        'Invalid native unresolved initial challenge.',
      );
    }
  }

  factory NativeInitialUnresolvedChallenge.fromJson(Object? value) {
    const keys = {'mode', 'nonce', 'launch', 'sdk', 'explicitNext'};
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !keys.every(value.containsKey) ||
        value['mode'] != mode ||
        value['nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['nonce'] as String) ||
        value['launch'] is! int ||
        (value['launch'] as int) < 1 ||
        (value['launch'] as int) > 4 ||
        value['sdk'] is! String ||
        value['explicitNext'] is! bool) {
      throw const FormatException(
        'Invalid unresolved initial challenge fields.',
      );
    }
    final launch = value['launch'] as int;
    final sdk = value['sdk'] as String;
    final next = value['explicitNext'] as bool;
    if (next != (launch >= 3) ||
        sdk.isEmpty ||
        sdk.contains(RegExp(r'[\x00\r\n]')) ||
        !path.posix.isAbsolute(sdk) ||
        path.posix.normalize(sdk) != sdk ||
        utf8.encode(jsonEncode(value)).length > maxEncodedBytes) {
      throw const FormatException(
        'Invalid unresolved initial challenge scope.',
      );
    }
    return NativeInitialUnresolvedChallenge._(
      nonce: value['nonce'] as String,
      launch: launch,
      sdk: sdk,
      explicitNext: next,
    );
  }

  Map<String, Object> toJson() => {
    'mode': mode,
    'nonce': nonce,
    'launch': launch,
    'sdk': sdk,
    'explicitNext': explicitNext,
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

  static const reportKeys = {
    'version',
    'mode',
    'nonce',
    'launch',
    'explicitNext',
    'stage',
    'projectId',
    'sessionId',
    'boardTaskId',
    'requirementId',
    'requestedModel',
    'requestCount',
    'unresolvedRequestNumber',
    'latestRequestNumber',
    'unresolvedRequestStatus',
    'latestRequestStatus',
    'unresolvedRequestSha256',
    'latestRequestSha256',
    'unresolvedResponseModel',
    'latestResponseModel',
    'unresolvedReturnedSourceSha256',
    'latestReturnedSourceSha256',
    'originalSessionSha256',
    'sessionRevision',
    'sessionDispatchCount',
    'requestReference',
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
    'terminalCommits',
    'liveTransportAttempts',
    'sdkAttempts',
    'candidateEffects',
    'unrelatedWrites',
    'previewAttempts',
    'sourceCopies',
    'hostCreations',
  };
}

StudioProject _project(NativeInitialUnresolvedChallenge c) => StudioProject(
  id: c.projectId,
  name: 'Supplied unresolved initial metadata',
  description: 'Fixed metadata only',
  type: 'Flutter',
  platforms: const ['Web'],
  location: '',
);

Future<void> _seed(
  StudioDatabase records,
  NativeInitialUnresolvedChallenge c,
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
const _after = 'void main() { /* supplied unresolved fixture return */ }';

Future<Map<String, String>> _raw(Database database) async => {
  for (final row in await StoreRef<String, String>('records').find(database))
    row.key: row.value,
};
void _same(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length || a.entries.any((e) => b[e.key] != e.value)) {
    throw StateError('Unresolved fixture physical records changed.');
  }
}

Map<String, String?> _slots(
  Map<String, String> raw,
  NativeInitialUnresolvedChallenge c,
) => {
  for (final e in c.recordSlots.entries)
    e.key: raw[e.value] == null ? null : _hash(raw[e.value]!),
};
String _unrelated(
  Map<String, String> raw,
  NativeInitialUnresolvedChallenge c,
) => _mapHash({
  for (final e in raw.entries)
    if (!c.recordSlots.values.contains(e.key)) e.key: e.value,
});

class _SuppliedProvider
    implements ModelProvider, ModelResponseIdentityProvider {
  bool _entered = false;
  @override
  String get completedResponseModel =>
      NativeInitialUnresolvedChallenge.suppliedModel;
  @override
  Stream<String> generate(String prompt) {
    if (_entered) throw StateError('Supplied provider may enter once only.');
    _entered = true;
    return Stream.value(
      jsonEncode({
        'summary': 'Fixed supplied request2 return',
        'changes': [
          {'path': 'lib/main.dart', 'before': _before, 'after': _after},
        ],
      }),
    );
  }

  @override
  Future<void> cancel() async {}
}

class _RequestRecords implements ConditionalRecordStorage {
  _RequestRecords(
    this.delegate,
    this.database,
    this.c,
    this.counts,
    this.onReserved,
  );
  final StudioDatabase delegate;
  final Database database;
  final NativeInitialUnresolvedChallenge c;
  final Map<String, int> counts;
  final Future<void> Function() onReserved;
  @override
  String? getString(String key) => delegate.getString(key);
  Never _refuse() {
    counts['unrelatedWrites'] = counts['unrelatedWrites']! + 1;
    throw StateError('No other fixture record write is authorized.');
  }

  @override
  Future<bool> setString(String key, String value) async => _refuse();
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    if (c.launch != 1 && c.launch != 3) _refuse();
    final key = c.recordSlots['requestJournal']!;
    if (updates.length != 1 || !updates.containsKey(key)) _refuse();
    final next = SessionProposalRequestJournal.decode(updates[key]!);
    final count = c.launch == 1 ? 1 : 2;
    if (next.requests.length != count) _refuse();
    final last = next.requests.last;
    final reserve = last.status == SessionProposalRequestStatus.reserved;
    if (last.number != count ||
        (!reserve &&
            (c.launch != 3 ||
                last.status !=
                    SessionProposalRequestStatus.returnedValidated)) ||
        (reserve && counts['reservationCommits'] != 0) ||
        (!reserve &&
            (counts['reservationReturns'] != 1 ||
                counts['terminalCommits'] != 0))) {
      _refuse();
    }
    final previous = delegate.getString(key);
    if (c.launch == 3) {
      final old = SessionProposalRequestJournal.decode(previous!);
      if (jsonEncode(next.requests.first.toJson()) !=
          jsonEncode(old.requests.first.toJson())) {
        _refuse();
      }
    } else if (previous != null) {
      _refuse();
    }
    await delegate.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
    final physical = await StoreRef<String, String>('records')
        .record(key)
        .get(database);
    if (physical != updates[key]) {
      throw StateError('Actual native request commit required.');
    }
    if (reserve) {
      counts['reservationCommits'] = counts['reservationCommits']! + 1;
      if (c.launch == 1) await onReserved(); // Must not return to the provider.
      counts['reservationReturns'] = counts['reservationReturns']! + 1;
    } else {
      counts['terminalCommits'] = counts['terminalCommits']! + 1;
    }
  }
}

Future<void> _writeCapture(
  String root,
  int stage,
  String nonce,
  Map<String, String> records,
) async {
  final file = File(path.join(root, 'capture-$stage.json'));
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('Fresh private capture required.');
  }
  final raw = jsonEncode({'nonce': nonce, 'records': records});
  if (utf8.encode(raw).length > 131072) {
    throw StateError('Capture exceeds bound.');
  }
  await file.writeAsString(raw, flush: true);
}

Future<Map<String, String>> _readCapture(
  String root,
  int stage,
  String nonce,
) async {
  final file = File(path.join(root, 'capture-$stage.json'));
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await file.length() > 131072) {
    throw StateError('Invalid private capture.');
  }
  final raw = await file.readAsString();
  rejectDuplicateJsonMembers(raw);
  final value = jsonDecode(raw);
  if (value is! Map<String, dynamic> ||
      value.length != 2 ||
      value['nonce'] != nonce ||
      value['records'] is! Map<String, dynamic>) {
    throw StateError('Capture identity changed.');
  }
  final records = value['records'] as Map<String, dynamic>;
  if (records.length > 128 || records.values.any((v) => v is! String)) {
    throw StateError('Invalid capture records.');
  }
  return records.cast<String, String>();
}

/// Disposable fixed fixture only. A VM hold release is not an app-process crash.
Future<void> runNativeInitialUnresolvedFixture(
  String root,
  String rawChallenge, {
  Future<void> Function()? holdAfterReport,
}) async {
  final c = NativeInitialUnresolvedChallenge.decode(rawChallenge);
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
  final file = File(path.join(root, 'initial-unresolved.db'));
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if ((c.launch == 1 && type != FileSystemEntityType.notFound) ||
      (c.launch != 1 && type != FileSystemEntityType.file)) {
    throw StateError('Unexpected native unresolved database stage.');
  }
  SharedPreferences.setPrefix('asg.nativeUnresolved.${c.nonce}.');
  final preferences = await SharedPreferences.getInstance();
  final database = await databaseFactoryIo.openDatabase(file.path);
  ApprovedSourceProposer? service;
  try {
    final opened = await _raw(database);
    final records = await StudioDatabase.migrate(database, preferences);
    if (c.launch != 1) _same(opened, await _raw(database));
    final counts = {
      for (final key in NativeInitialUnresolvedChallenge.counterKeys) key: 0,
    };
    final project = _project(c);
    if (c.launch == 1) {
      await _seed(records, c, root);
      counts['setupCalls'] = 1;
    }
    final before = await _raw(database);
    Map<String, String>? first;
    if (c.launch != 1) {
      first = await _readCapture(root, 1, c.nonce);
      final expected = c.launch == 4
          ? await _readCapture(root, 3, c.nonce)
          : first;
      _same(before, expected);
    }
    Future<void> report() async {
      final after = await _raw(database);
      final key = c.recordSlots['requestJournal']!;
      final requests = SessionProposalRequestJournal.decode(after[key]!)
          .requests;
      final original = requests.first, latest = requests.last;
      if (original.number != 1 ||
          original.status != SessionProposalRequestStatus.reserved ||
          original.modelRequest.responseModel != null ||
          original.returnedSha256.isNotEmpty ||
          requests.length != (c.launch >= 3 ? 2 : 1)) {
        throw StateError('Unresolved request identity changed.');
      }
      if (first != null) {
        final saved = SessionProposalRequestJournal.decode(first[key]!)
            .requests
            .single;
        if (jsonEncode(saved.toJson()) != jsonEncode(original.toJson())) {
          throw StateError('Original unresolved request changed.');
        }
        _same({...after}..remove(key), {...first}..remove(key));
      }
      final sessionRaw = after[c.recordSlots['session']]!;
      final session = AgentSession.fromJson(jsonDecode(sessionRaw));
      final working = GeneratedProject.fromJson(
        jsonDecode(after[c.recordSlots['working']]!),
      );
      if (session.revision != 0 ||
          session.dispatches.isNotEmpty ||
          original.sessionSha256 != _hash(sessionRaw)) {
        throw StateError('Original selected session changed.');
      }
      final active = c.launch >= 3;
      if (latest.number != (active ? 2 : 1) ||
          latest.status !=
              (active
                  ? SessionProposalRequestStatus.returnedValidated
                  : SessionProposalRequestStatus.reserved) ||
          latest.modelRequest.model !=
              NativeInitialUnresolvedChallenge.suppliedModel ||
          latest.modelRequest.responseModel !=
              (active
                  ? NativeInitialUnresolvedChallenge.suppliedModel
                  : null) ||
          (active && latest.returnedSha256.isEmpty)) {
        throw StateError('Latest request outcome changed.');
      }
      final expectedCounts = {
        for (final k in NativeInitialUnresolvedChallenge.counterKeys) k: 0,
      };
      if (c.launch == 1) {
        for (final k in ['setupCalls', 'proposalCalls', 'reservationCommits']) {
          expectedCounts[k] = 1;
        }
      } else if (c.launch == 3) {
        for (final k in [
          'proposalCalls',
          'reservationCommits',
          'reservationReturns',
          'suppliedProviderCalls',
          'proposalReturns',
          'terminalCommits',
        ]) {
          expectedCounts[k] = 1;
        }
      }
      if (counts.entries.any((e) => expectedCounts[e.key] != e.value)) {
        throw StateError('Unexpected fixture effects.');
      }
      final beforeSlots = _slots(before, c), afterSlots = _slots(after, c);
      for (final slot in c.recordSlots.keys.where(
        (k) => !['working', 'requestJournal', 'session'].contains(k),
      )) {
        if (beforeSlots[slot] != null || afterSlots[slot] != null) {
          throw StateError('Unexpected execution/candidate record.');
        }
      }
      if (_unrelated(before, c) != _unrelated(after, c) ||
          beforeSlots['working'] != afterSlots['working'] ||
          beforeSlots['session'] != afterSlots['session']) {
        throw StateError('Unrelated fixture records changed.');
      }
      if (c.launch == 2 || c.launch == 4) _same(before, after);
      final value = <String, Object?>{
        'version': 24,
        'mode': NativeInitialUnresolvedChallenge.mode,
        'nonce': c.nonce,
        'launch': c.launch,
        'explicitNext': c.explicitNext,
        'stage': c.stage,
        'projectId': c.projectId,
        'sessionId': c.sessionId,
        'boardTaskId': 'Tanalyze',
        'requirementId': 'R1',
        'requestedModel': NativeInitialUnresolvedChallenge.suppliedModel,
        'requestCount': requests.length,
        'unresolvedRequestNumber': 1,
        'latestRequestNumber': latest.number,
        'unresolvedRequestStatus': original.status.name,
        'latestRequestStatus': latest.status.name,
        'unresolvedRequestSha256': _hash(jsonEncode(original.toJson())),
        'latestRequestSha256': _hash(jsonEncode(latest.toJson())),
        'unresolvedResponseModel': null,
        'latestResponseModel': latest.modelRequest.responseModel,
        'unresolvedReturnedSourceSha256': null,
        'latestReturnedSourceSha256': active
            ? _mapHash(latest.returnedSha256)
            : null,
        'originalSessionSha256': _hash(sessionRaw),
        'sessionRevision': session.revision,
        'sessionDispatchCount': session.dispatches.length,
        'requestReference': active
            ? SessionProposalRequestReference.fromRequest(latest).toJson()
            : null,
        'recordsBefore': beforeSlots,
        'recordsAfter': afterSlots,
        'unrelatedBeforeSha256': _unrelated(before, c),
        'unrelatedAfterSha256': _unrelated(after, c),
        'declaredSourceSha256': _mapHash(working.sources),
        'counters': counts,
      };
      if (value.keys
              .toSet()
              .difference(NativeInitialUnresolvedChallenge.reportKeys)
              .isNotEmpty ||
          value.length != NativeInitialUnresolvedChallenge.reportKeys.length) {
        throw StateError('Report schema drift.');
      }
      final encoded = jsonEncode(value);
      if (utf8.encode(encoded).length >
          NativeInitialUnresolvedChallenge.maxReportBytes) {
        throw StateError('Report exceeds bound.');
      }
      final output = File(path.join(root, 'launch-${c.launch}.json'));
      if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Fresh report required.');
      }
      if (c.launch == 1 || c.launch == 3) {
        await _writeCapture(root, c.launch, c.nonce, after);
      }
      await output.writeAsString(encoded, flush: true);
      if (c.launch == 1 || c.launch == 3) {
        if (holdAfterReport != null) {
          await holdAfterReport();
        } else {
          await Completer<void>().future;
        }
        throw StateError('Fixture pause must not return.');
      }
    }

    final guarded = _RequestRecords(records, database, c, counts, report);
    if (c.launch == 2 || c.launch == 4) {
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
    counts['proposalCalls'] = counts['proposalCalls']! + 1;
    final evidence = await service.propose(
      project: project,
      boardTaskId: 'Tanalyze',
      config: const LocalModelConfig(
        model: NativeInitialUnresolvedChallenge.suppliedModel,
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
    counts['proposalReturns'] = counts['proposalReturns']! + 1;
    if (c.launch != 3 ||
        evidence.initialRequestOrigin?.reference.number != 2 ||
        evidence.initialRequestOrigin!.requestSessionRecord !=
            first![c.recordSlots['session']] ||
        evidence.modelRequest?.responseModel !=
            NativeInitialUnresolvedChallenge.suppliedModel) {
      throw StateError('Fresh explicit request2 origin required.');
    }
    final journal = SessionProposalRequestStore(
      guarded,
      c.projectId,
      c.sessionId,
    ).load();
    if (!evidence.initialRequestOrigin!.reference.matches(
          journal.requests.last,
        ) ||
        evidence.initialRequestOrigin!.reference.matches(
          journal.requests.first,
        )) {
      throw StateError('Fresh origin aliases unresolved request.');
    }
    await report();
  } finally {
    try {
      await service?.cancel();
    } finally {
      await database.close();
    }
  }
}

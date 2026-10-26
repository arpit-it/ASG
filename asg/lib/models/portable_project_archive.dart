import 'dart:convert';

import 'chat_message.dart';
import 'requirements_board.dart';
import 'structured_proposal_json.dart';

/// Data-only first F08 slice. No project identity, paths, settings or approval
/// credentials are portable. Text is retained verbatim and may be private;
/// callers must let users review it before sharing an archive.
class PortableProjectArchive {
  PortableProjectArchive({
    required this.requirements,
    this.decision,
    List<PortableRevisionSummary> revisions = const [],
    required List<ChatMessage> messages,
  }) : revisions = List.unmodifiable(revisions),
       messages = List.unmodifiable(
         messages.map((m) => ChatMessage(role: m.role, content: m.content)),
       ) {
    _validate();
  }

  static const maxBytes = 1024 * 1024;
  static const maxMessages = 1000;
  static const maxMessageCharacters = 100000;
  final List<PortableRevisionSummary> revisions;
  final PortablePlanDecision? decision;
  final RequirementsBoard requirements;
  final List<ChatMessage> messages;

  void _validate() {
    requirements.validate();
    if (revisions.length > 1000) {
      throw const FormatException('Too many historical revision summaries.');
    }
    if (requirements.revision == 0 &&
        (requirements.requirements.isNotEmpty ||
            requirements.tasks.isNotEmpty)) {
      throw const FormatException('An unsaved board must be empty.');
    }
    if (messages.length > maxMessages ||
        messages.any(
          (m) =>
              !const ['user', 'assistant'].contains(m.role) ||
              m.content.length > maxMessageCharacters,
        )) {
      throw const FormatException('Unsupported archive conversation.');
    }
  }

  Map<String, Object?> _json() => {
    'format': 'asg-portable-records',
    'version': revisions.any((r) => r.requirementsRevision != null)
        ? 4
        : (revisions.isNotEmpty ? 3 : (decision == null ? 1 : 2)),
    if (revisions.isNotEmpty)
      'revisions': revisions
          .map(
            (r) => r.toJson(
              includeInputRevisions: revisions.any(
                (r) => r.requirementsRevision != null,
              ),
            ),
          )
          .toList(),
    if (revisions.isNotEmpty && decision == null) 'decision': null,
    if (decision != null) 'decision': decision!.toJson(),
    'requirements': requirements.toJson(),
    'messages': messages
        .map((m) => {'role': m.role, 'content': m.content})
        .toList(),
  };

  String encode() {
    _validate();
    final encoded = jsonEncode(_json());
    if (utf8.encode(encoded).length > maxBytes) {
      throw const FormatException('Archive exceeds the 1 MiB limit.');
    }
    return encoded;
  }

  /// Rejects unknown fields rather than silently discarding future data or
  /// importing hidden execution credentials. Decoding performs no writes.
  factory PortableProjectArchive.decode(String encoded) {
    if (encoded.length > maxBytes || utf8.encode(encoded).length > maxBytes) {
      throw const FormatException('Archive exceeds the 1 MiB limit.');
    }
    try {
      final decoded = jsonDecode(encoded);
      // Validate syntax first; duplicate keys must not collapse into lost records.
      rejectDuplicateJsonMembers(encoded);
      final version = decoded is Map ? decoded['version'] : null;
      final root = _object(decoded, [
        'format',
        'version',
        'requirements',
        'messages',
        if (version == 2 || version == 3 || version == 4) 'decision',
        if (version == 3 || version == 4) 'revisions',
      ]);
      if (root['format'] != 'asg-portable-records' ||
          root['version'] is! int ||
          !const [1, 2, 3, 4].contains(root['version'])) {
        throw const FormatException('Unsupported portable archive version.');
      }
      final board = _object(root['requirements'], const [
        'version',
        'revision',
        'requirements',
        'tasks',
      ]);
      final requirementRows = board['requirements'] as List;
      final taskRows = board['tasks'] as List;
      if (requirementRows.length > 100 || taskRows.length > 200) {
        throw const FormatException('Archive board exceeds supported limits.');
      }
      for (final row in requirementRows) {
        _object(row, const ['id', 'title', 'acceptance']);
      }
      for (final row in taskRows) {
        _object(row, const [
          'id',
          'requirementId',
          'title',
          'dependencies',
          'status',
        ]);
      }
      // A never-saved empty board has revision zero in application state,
      // whereas durable board records start at one.
      final RequirementsBoard requirements;
      if (board['version'] is! int || board['revision'] is! int) {
        throw const FormatException('Invalid board version or revision.');
      }
      if (board['version'] == 1 &&
          board['revision'] == 0 &&
          requirementRows.isEmpty &&
          taskRows.isEmpty) {
        requirements = RequirementsBoard();
      } else {
        requirements = RequirementsBoard.fromJson(board);
      }
      final rows = root['messages'] as List;
      if (rows.length > maxMessages) {
        throw const FormatException('Archive has too many messages.');
      }
      return PortableProjectArchive(
        requirements: requirements,
        revisions: version == 3 || version == 4
            ? PortableRevisionSummary.parseList(
                root['revisions'],
                inputRevisions: version == 4,
              )
            : const [],
        decision:
            version == 2 ||
                ((version == 3 || version == 4) && root['decision'] != null)
            ? PortablePlanDecision.fromJson(root['decision'])
            : null,
        messages: rows.map((row) {
          final message = _object(row, const ['role', 'content']);
          return ChatMessage(
            role: message['role'] as String,
            content: message['content'] as String,
          );
        }).toList(),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed portable archive records.');
    }
  }

  static Map<String, dynamic> _object(Object? value, List<String> fields) {
    if (value is! Map<String, dynamic> ||
        value.length != fields.length ||
        !fields.every(value.containsKey)) {
      throw const FormatException('Unsupported portable archive fields.');
    }
    return value;
  }
}

/// Historical information only: no execution context or message index.
class PortablePlanDecision {
  PortablePlanDecision({
    required this.content,
    required this.approved,
    required DateTime recordedAt,
  }) : recordedAt = recordedAt.toUtc() {
    if (content.isEmpty ||
        content.length > PortableProjectArchive.maxMessageCharacters) {
      throw const FormatException('Unsupported historical Plan decision.');
    }
  }
  final String content;
  final bool approved;
  final DateTime recordedAt;
  Map<String, Object> toJson() => {
    'content': content,
    'approved': approved,
    'recordedAt': recordedAt.toIso8601String(),
  };
  factory PortablePlanDecision.fromJson(Object? value) {
    final row = PortableProjectArchive._object(value, const [
      'content',
      'approved',
      'recordedAt',
    ]);
    final content = row['content'];
    final approved = row['approved'];
    final timestamp = row['recordedAt'];
    if (content is! String || approved is! bool || timestamp is! String) {
      throw const FormatException('Malformed historical Plan decision.');
    }
    final date = DateTime.tryParse(timestamp);
    if (date == null || !date.isUtc || date.toIso8601String() != timestamp) {
      throw const FormatException('Invalid historical decision timestamp.');
    }
    return PortablePlanDecision(
      content: content,
      approved: approved,
      recordedAt: date,
    );
  }
}

/// Historical terminal outcome only, without paths, logs or execution authority.
class PortableRevisionSummary {
  PortableRevisionSummary({
    required DateTime? recordedAt,
    required this.outcome,
    required this.passedChecks,
    required this.totalChecks,
    this.requirementsRevision,
    this.prototypeRevision,
  }) : recordedAt = recordedAt?.toUtc() {
    if ((requirementsRevision == null) != (prototypeRevision == null) ||
        (requirementsRevision != null &&
            (requirementsRevision! < 0 ||
                requirementsRevision! > 9007199254740991)) ||
        (prototypeRevision != null &&
            (prototypeRevision! < 1 ||
                prototypeRevision! > 9007199254740991)) ||
        !const ['ready', 'failed'].contains(outcome) ||
        totalChecks < 0 ||
        totalChecks > 4 ||
        passedChecks < 0 ||
        passedChecks > totalChecks ||
        (outcome == 'ready' && (totalChecks != 4 || passedChecks != 4))) {
      throw const FormatException('Invalid historical revision summary.');
    }
  }
  final DateTime? recordedAt;
  final String outcome;
  final int passedChecks, totalChecks;
  final int? requirementsRevision, prototypeRevision;
  Map<String, Object?> toJson({bool includeInputRevisions = true}) => {
    if (includeInputRevisions) 'requirementsRevision': requirementsRevision,
    if (includeInputRevisions) 'prototypeRevision': prototypeRevision,
    'recordedAt': recordedAt?.toIso8601String(),
    'outcome': outcome,
    'passedChecks': passedChecks,
    'totalChecks': totalChecks,
  };
  static List<PortableRevisionSummary> parseList(
    Object? value, {
    bool? inputRevisions,
  }) {
    if (value is! List || value.length > 1000) {
      throw const FormatException('Invalid historical revision list.');
    }
    return List.unmodifiable(
      value.map((row) {
        final hasInputs =
            inputRevisions ??
            (row is Map &&
                (row.containsKey('requirementsRevision') ||
                    row.containsKey('prototypeRevision')));
        final json = PortableProjectArchive._object(row, [
          if (hasInputs) 'requirementsRevision',
          if (hasInputs) 'prototypeRevision',
          'recordedAt',
          'outcome',
          'passedChecks',
          'totalChecks',
        ]);
        final timestamp = json['recordedAt'];
        final date = timestamp is String ? DateTime.tryParse(timestamp) : null;
        if ((timestamp != null &&
                (date == null ||
                    !date.isUtc ||
                    date.toIso8601String() != timestamp)) ||
            json['outcome'] is! String ||
            json['passedChecks'] is! int ||
            json['totalChecks'] is! int ||
            (hasInputs &&
                ((json['requirementsRevision'] != null &&
                        json['requirementsRevision'] is! int) ||
                    (json['prototypeRevision'] != null &&
                        json['prototypeRevision'] is! int)))) {
          throw const FormatException('Malformed historical revision summary.');
        }
        return PortableRevisionSummary(
          recordedAt: date,
          outcome: json['outcome'] as String,
          passedChecks: json['passedChecks'] as int,
          totalChecks: json['totalChecks'] as int,
          requirementsRevision: json['requirementsRevision'] as int?,
          prototypeRevision: json['prototypeRevision'] as int?,
        );
      }),
    );
  }
}

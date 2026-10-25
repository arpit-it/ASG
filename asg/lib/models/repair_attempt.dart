import 'candidate_verification_run.dart';
import 'candidate_failure.dart';
import 'source_edit_proposal.dart';

enum RepairAttemptStatus { reserved, proposed, failed, cancelled }

/// A model request outcome. Proposed never means repaired or checks passed.
class RepairAttempt {
  const RepairAttempt({
    required this.number,
    required this.startedAt,
    required this.failure,
    required this.status,
    this.proposal,
  });
  final int number;
  final DateTime startedAt;
  final CandidateVerificationRun failure;
  final RepairAttemptStatus status;
  final SourceEditProposal? proposal;
  String get category => failure.snapshot.steps.last.operation;

  Map<String, Object?> toJson() => {
    'number': number,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'failure': failure.toJson(),
    'status': status.name,
    'proposal': proposal == null
        ? null
        : {
            'summary': proposal!.summary,
            'changes': [
              for (final change in proposal!.changes)
                {
                  'path': change.path,
                  'before': change.before,
                  'after': change.after,
                },
            ],
          },
  };

  factory RepairAttempt.fromJson(Map<String, dynamic> json) {
    if (json.length != 5 ||
        json['number'] is! int ||
        (json['number'] as int) < 1 ||
        json['startedAt'] is! String ||
        json['failure'] is! Map<String, dynamic> ||
        !RepairAttemptStatus.values.any((s) => s.name == json['status'])) {
      throw const FormatException('Invalid repair attempt.');
    }
    final failure = CandidateVerificationRun.fromJson(
      json['failure'] as Map<String, dynamic>,
    );
    final snapshot = failure.snapshot;
    final step = snapshot.steps.isEmpty ? null : snapshot.steps.last;
    if (CandidateFailure.inspect(snapshot, active: false)?.kind !=
            CandidateFailureKind.sourceCheckFailure ||
        !failure.finished ||
        snapshot.approval == null ||
        step == null ||
        !['analyze', 'test', 'build'].contains(step.operation) ||
        step.exitCode <= 0 ||
        step.cancelled ||
        step.timedOut ||
        step.outputLimitExceeded ||
        snapshot.pendingOperation.isNotEmpty ||
        snapshot.failedOperation.isNotEmpty) {
      throw const FormatException('Invalid repair failure evidence.');
    }
    final time = DateTime.parse(json['startedAt'] as String);
    if (!time.isUtc) {
      throw const FormatException('Repair timestamp must be UTC.');
    }
    final status = RepairAttemptStatus.values.singleWhere(
      (s) => s.name == json['status'],
    );
    SourceEditProposal? proposal;
    if (status == RepairAttemptStatus.proposed) {
      final raw = json['proposal'];
      if (raw is! Map || raw['changes'] is! List) {
        throw const FormatException('Missing repair proposal.');
      }
      final originals = <String, String>{};
      for (final entry in raw['changes'] as List) {
        if (entry is! Map ||
            entry['path'] is! String ||
            entry['before'] is! String) {
          throw const FormatException('Invalid repair change.');
        }
        originals[entry['path'] as String] = entry['before'] as String;
      }
      proposal = SourceEditProposal.parse(raw, originals: originals);
    } else if (json['proposal'] != null) {
      throw const FormatException('Unexpected repair proposal.');
    }
    return RepairAttempt(
      number: json['number'] as int,
      startedAt: time,
      failure: failure,
      status: status,
      proposal: proposal,
    );
  }
}

class RepairAttemptJournal {
  RepairAttemptJournal(Iterable<RepairAttempt> attempts)
    : attempts = List.unmodifiable(attempts);
  final List<RepairAttempt> attempts;
  Map<String, Object> toJson() => {
    'version': 1,
    'attempts': [for (final a in attempts) a.toJson()],
  };
  factory RepairAttemptJournal.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        json['version'] is! int ||
        json['version'] != 1 ||
        json['attempts'] is! List) {
      throw const FormatException('Invalid repair journal.');
    }
    final attempts = <RepairAttempt>[];
    for (final entry in json['attempts'] as List) {
      final attempt = RepairAttempt.fromJson(
        Map<String, dynamic>.from(entry as Map),
      );
      if (attempt.number != attempts.length + 1) {
        throw const FormatException('Invalid repair sequence.');
      }
      final used = attempts
          .where(
            (a) =>
                a.category == attempt.category &&
                a.failure.snapshot.approval!.matches(
                  attempt.failure.snapshot.approval!,
                ),
          )
          .length;
      if (used >= 3) throw const FormatException('Repair budget exceeded.');
      attempts.add(attempt);
    }
    return RepairAttemptJournal(attempts);
  }
}

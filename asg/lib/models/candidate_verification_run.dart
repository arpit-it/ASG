// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'source_generation.dart';

/// Manual candidate checks, not automatic model repair attempts or authority.
class CandidateVerificationRun {
  const CandidateVerificationRun({
    required this.number,
    required this.startedAt,
    required this.snapshot,
    required this.finished,
  });
  final int number;
  final DateTime startedAt;
  final GeneratedProject snapshot;
  final bool finished;

  String get status => !finished
      ? 'interrupted or still active'
      : snapshot.phase == SourceGenerationPhase.ready
      ? 'checks passed'
      : 'stopped';

  Map<String, Object> toJson() => {
    'number': number,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'snapshot': snapshot.toJson(),
    'finished': finished,
  };

  factory CandidateVerificationRun.fromJson(Map<String, dynamic> json) {
    if (json.length != 4 ||
        json['number'] is! int ||
        (json['number'] as int) < 1 ||
        json['startedAt'] is! String ||
        json['finished'] is! bool ||
        json['snapshot'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid candidate verification run.');
    }
    final snapshot = GeneratedProject.fromJson(
      json['snapshot'] as Map<String, dynamic>,
    );
    if (!snapshot.confined ||
        (json['finished'] == true &&
            snapshot.phase != SourceGenerationPhase.ready &&
            snapshot.phase != SourceGenerationPhase.failed)) {
      throw const FormatException('Invalid candidate verification outcome.');
    }
    final startedAt = DateTime.parse(json['startedAt'] as String);
    if (!startedAt.isUtc) {
      throw const FormatException('Verification timestamp must be UTC.');
    }
    return CandidateVerificationRun(
      number: json['number'] as int,
      startedAt: startedAt,
      snapshot: snapshot,
      finished: json['finished'] as bool,
    );
  }
}

class CandidateVerificationJournal {
  CandidateVerificationJournal(Iterable<CandidateVerificationRun> runs)
    : runs = List.unmodifiable(runs);
  final List<CandidateVerificationRun> runs;
  Map<String, Object> toJson() => {
    'version': 1,
    'runs': runs.map((run) => run.toJson()).toList(),
  };

  factory CandidateVerificationJournal.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        json['version'] is! int ||
        json['version'] != 1 ||
        json['runs'] is! List) {
      throw const FormatException(
        'Unsupported candidate verification journal.',
      );
    }
    final runs = (json['runs'] as List)
        .map(
          (run) => CandidateVerificationRun.fromJson(
            Map<String, dynamic>.from(run as Map),
          ),
        )
        .toList();
    for (var i = 0; i < runs.length; i++) {
      if (runs[i].number != i + 1) {
        throw const FormatException('Invalid verification run sequence.');
      }
    }
    return CandidateVerificationJournal(runs);
  }
}

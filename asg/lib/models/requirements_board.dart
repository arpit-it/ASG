// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

enum TaskStatus { queued, inProgress, blocked, done }

enum AcceptanceCheckType { automated, manual, advisory }

/// A literal named-test selection, not a shell command or execution grant.
class FlutterTestTarget {
  const FlutterTestTarget({required this.file, required this.name});
  final String file, name;
  void validate() {
    if (file.length > 240 ||
        !RegExp(r'^test/(?:[a-zA-Z0-9_]+/)*[a-zA-Z0-9_]+_test\.dart$')
            .hasMatch(file) ||
        name.trim().isEmpty ||
        name.length > 200 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException(
        'Choose a relative test/…_test.dart file and a nonempty exact test name (at most 200 characters; no control characters).',
      );
    }
  }

  Map<String, Object> toJson() => {
    'runner': 'flutterTest',
    'file': file,
    'name': name,
  };
  factory FlutterTestTarget.fromJson(Map<String, dynamic> json) {
    if (json.length != 3 ||
        json['runner'] != 'flutterTest' ||
        json['file'] is! String ||
        json['name'] is! String) {
      throw const FormatException('Invalid Flutter test target.');
    }
    final target = FlutterTestTarget(
      file: json['file'] as String,
      name: json['name'] as String,
    );
    target.validate();
    return target;
  }
}

/// An authored mapping, not permission to execute or evidence that it passed.
class AcceptanceCheckDefinition {
  const AcceptanceCheckDefinition({
    required this.id,
    required this.type,
    required this.expectation,
    this.target,
  });
  final String id, expectation;
  final AcceptanceCheckType type;
  final FlutterTestTarget? target;
  void validate() {
    if (target != null && type != AcceptanceCheckType.automated) {
      throw const FormatException(
        'Only automated checks can select a Flutter test target.',
      );
    }
    target?.validate();
  }

  Map<String, Object> toJson() => {
    'id': id,
    'type': type.name,
    'expectation': expectation,
    if (target != null) 'target': target!.toJson(),
  };
  factory AcceptanceCheckDefinition.fromJson(Map<String, dynamic> json) {
    if ((json.length != 3 && json.length != 4) ||
        json.keys.any(
          (k) => !const ['id', 'type', 'expectation', 'target'].contains(k),
        ) ||
        (json.containsKey('target') &&
            json['target'] is! Map<String, dynamic>) ||
        json['id'] is! String ||
        json['expectation'] is! String ||
        json['type'] is! String) {
      throw const FormatException('Invalid acceptance check definition.');
    }
    final check = AcceptanceCheckDefinition(
      id: json['id'] as String,
      type: AcceptanceCheckType.values.byName(json['type'] as String),
      expectation: json['expectation'] as String,
      target: json.containsKey('target')
          ? FlutterTestTarget.fromJson(json['target'] as Map<String, dynamic>)
          : null,
    );
    check.validate();
    return check;
  }
}

/// Explicit user-authored criterion and local check references. No prose parsing
/// or inferred coverage: an empty mapping is allowed and visibly unmet.
enum CriterionVerificationRule { none, allMappedNamedTests }

class AcceptanceCriterionDefinition {
  AcceptanceCriterionDefinition({
    required this.id,
    required this.text,
    List<String> checkIds = const [],
    this.verificationRule = CriterionVerificationRule.none,
  }) : checkIds = List.unmodifiable(checkIds);
  final String id, text;
  final List<String> checkIds;
  final CriterionVerificationRule verificationRule;
  Map<String, Object> toJson() => {
    'id': id,
    'text': text,
    'checkIds': checkIds,
    if (verificationRule != CriterionVerificationRule.none)
      'verificationRule': verificationRule.name,
  };
  factory AcceptanceCriterionDefinition.fromJson(Map<String, dynamic> json) {
    if ((json.length != 3 && json.length != 4) ||
        json.keys.any(
          (k) =>
              !const ['id', 'text', 'checkIds', 'verificationRule'].contains(k),
        ) ||
        (json.containsKey('verificationRule') &&
            (json['verificationRule'] is! String ||
                !CriterionVerificationRule.values.any(
                  (v) => v.name == json['verificationRule'],
                ))) ||
        json['id'] is! String ||
        json['text'] is! String ||
        json['checkIds'] is! List ||
        (json['checkIds'] as List).any((v) => v is! String)) {
      throw const FormatException('Invalid acceptance criterion definition.');
    }
    return AcceptanceCriterionDefinition(
      id: json['id'] as String,
      text: json['text'] as String,
      checkIds: (json['checkIds'] as List).cast<String>(),
      verificationRule: json.containsKey('verificationRule')
          ? CriterionVerificationRule.values.byName(
              json['verificationRule'] as String,
            )
          : CriterionVerificationRule.none,
    );
  }
}

class ProjectRequirement {
  ProjectRequirement({
    required this.id,
    required this.title,
    required this.acceptance,
    List<AcceptanceCheckDefinition> checks = const [],
    List<AcceptanceCriterionDefinition> criteria = const [],
  }) : checks = List.unmodifiable(checks),
       criteria = List.unmodifiable(criteria);
  final String id, title, acceptance;
  final List<AcceptanceCheckDefinition> checks;
  final List<AcceptanceCriterionDefinition> criteria;
  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'acceptance': acceptance,
    if (checks.isNotEmpty) 'checks': checks.map((c) => c.toJson()).toList(),
    if (criteria.isNotEmpty)
      'criteria': criteria.map((c) => c.toJson()).toList(),
  };
  factory ProjectRequirement.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('checks') && json['checks'] is! List) {
      throw const FormatException('Invalid acceptance check declarations.');
    }
    if (json.containsKey('criteria') && json['criteria'] is! List) {
      throw const FormatException('Invalid acceptance criteria.');
    }
    return ProjectRequirement(
      criteria: [
        for (final c in json['criteria'] as List? ?? const [])
          AcceptanceCriterionDefinition.fromJson(c as Map<String, dynamic>),
      ],
      id: json['id'] as String,
      title: json['title'] as String,
      acceptance: json['acceptance'] as String,
      checks: List.unmodifiable(
        (json['checks'] as List? ?? const []).map(
          (c) => AcceptanceCheckDefinition.fromJson(c as Map<String, dynamic>),
        ),
      ),
    );
  }
}

class DevelopmentTask {
  DevelopmentTask({
    required this.id,
    required this.requirementId,
    required this.title,
    List<String> dependencies = const [],
    this.status = TaskStatus.queued,
  }) : dependencies = List.unmodifiable(dependencies);
  final String id, requirementId, title;
  final List<String> dependencies;
  final TaskStatus status;
  DevelopmentTask withStatus(TaskStatus value) => DevelopmentTask(
    id: id,
    requirementId: requirementId,
    title: title,
    dependencies: dependencies,
    status: value,
  );
  Map<String, Object> toJson() => {
    'id': id,
    'requirementId': requirementId,
    'title': title,
    'dependencies': dependencies,
    'status': status.name,
  };
  factory DevelopmentTask.fromJson(Map<String, dynamic> json) =>
      DevelopmentTask(
        id: json['id'] as String,
        requirementId: json['requirementId'] as String,
        title: json['title'] as String,
        dependencies: (json['dependencies'] as List).cast<String>(),
        status: TaskStatus.values.byName(json['status'] as String),
      );
}

/// A single atomic, versioned requirements/task record. IDs remain stable on edits.
class RequirementsBoard {
  RequirementsBoard({
    this.revision = 0,
    List<ProjectRequirement> requirements = const [],
    List<DevelopmentTask> tasks = const [],
  }) : requirements = List.unmodifiable(requirements),
       tasks = List.unmodifiable(tasks);
  final int revision;
  final List<ProjectRequirement> requirements;
  final List<DevelopmentTask> tasks;
  void validate() {
    if (revision < 0 || requirements.length > 100 || tasks.length > 200) {
      throw const FormatException(
        'Requirements board exceeds its supported limits.',
      );
    }
    void id(String value) {
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,39}$').hasMatch(value)) {
        throw const FormatException(
          'IDs must start with a letter and contain up to 40 letters, digits, underscores or hyphens.',
        );
      }
    }

    void text(String value, int limit) {
      if (value.trim().isEmpty || value.length > limit) {
        throw FormatException(
          'Enter nonempty text of at most $limit characters.',
        );
      }
    }

    final ids = <String>{};
    for (final r in requirements) {
      id(r.id);
      text(r.title, 200);
      text(r.acceptance, 2000);
      if (r.checks.length > 10) {
        throw const FormatException(
          'Use at most 10 acceptance checks per requirement.',
        );
      }
      final checkIds = <String>{};
      for (final check in r.checks) {
        check.validate();
        id(check.id);
        text(check.expectation, 500);
        if (!checkIds.add(check.id)) {
          throw const FormatException(
            'Acceptance check IDs must be unique within a requirement.',
          );
        }
      }
      if (r.criteria.length > 10) {
        throw const FormatException(
          'Use at most 10 authored criteria per requirement.',
        );
      }
      final criterionIds = <String>{};
      for (final criterion in r.criteria) {
        id(criterion.id);
        text(criterion.text, 500);
        if (!criterionIds.add(criterion.id)) {
          throw const FormatException(
            'Criterion IDs must be unique within a requirement.',
          );
        }
        if (criterion.checkIds.length > 10 ||
            criterion.checkIds.toSet().length != criterion.checkIds.length ||
            criterion.checkIds.any((v) => !checkIds.contains(v))) {
          throw const FormatException(
            'Map unique existing check IDs from this requirement to each criterion. Fix mappings before removing or renaming a check.',
          );
        }
        if (criterion.verificationRule ==
                CriterionVerificationRule.allMappedNamedTests &&
            (criterion.checkIds.isEmpty ||
                criterion.checkIds.any(
                  (id) => !r.checks.any(
                    (c) =>
                        c.id == id &&
                        c.type == AcceptanceCheckType.automated &&
                        c.target != null,
                  ),
                ))) {
          throw const FormatException(
            'The named-test verification rule requires at least one mapping, all to automated checks with exact Flutter test targets.',
          );
        }
      }
      if (!ids.add(r.id)) {
        throw const FormatException('Requirement IDs must be unique.');
      }
    }
    final byId = <String, DevelopmentTask>{};
    for (final t in tasks) {
      id(t.id);
      text(t.title, 200);
      if (byId.containsKey(t.id)) {
        throw const FormatException('Task IDs must be unique.');
      }
      if (!ids.contains(t.requirementId)) {
        throw const FormatException(
          'Select an existing requirement for each task.',
        );
      }
      byId[t.id] = t;
    }
    final visited = <String>{}, visiting = <String>{};
    void visit(DevelopmentTask t) {
      if (visited.contains(t.id)) return;
      if (!visiting.add(t.id)) {
        throw const FormatException(
          'Task dependencies must not contain cycles.',
        );
      }
      if (t.dependencies.toSet().length != t.dependencies.length) {
        throw const FormatException('Task dependencies must be unique.');
      }
      for (final dep in t.dependencies) {
        final prerequisite = byId[dep];
        if (prerequisite == null) {
          throw const FormatException('A task dependency does not exist.');
        }
        visit(prerequisite);
        if (t.status == TaskStatus.done &&
            prerequisite.status != TaskStatus.done) {
          throw const FormatException(
            'Complete prerequisites before completing this task.',
          );
        }
      }
      visiting.remove(t.id);
      visited.add(t.id);
    }

    for (final task in tasks) {
      visit(task);
    }
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'revision': revision,
    'requirements': requirements.map((r) => r.toJson()).toList(),
    'tasks': tasks.map((t) => t.toJson()).toList(),
  };
  factory RequirementsBoard.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['revision'] is! int ||
        (json['revision'] as int) < 1) {
      throw const FormatException(
        'Unsupported requirements board version or revision.',
      );
    }
    final board = RequirementsBoard(
      revision: json['revision'] as int,
      requirements: (json['requirements'] as List)
          .map((r) => ProjectRequirement.fromJson(r as Map<String, dynamic>))
          .toList(),
      tasks: (json['tasks'] as List)
          .map((t) => DevelopmentTask.fromJson(t as Map<String, dynamic>))
          .toList(),
    );
    board.validate();
    return board;
  }

  static const planContextLimit = 12000;

  /// Approval must never bind a draft made from a partial requirements board.
  String planDocument(String projectName) {
    final complete = document(projectName);
    if (complete.length > planContextLimit) {
      throw StateError(
        'Plan needs the complete requirements and task board. Its readable '
        'document is ${complete.length} characters; the current limit '
        'is $planContextLimit. Shorten requirement descriptions, acceptance '
        'criteria or task titles in the requirements board, then draft a new Plan.',
      );
    }
    return complete;
  }

  String document(String projectName) {
    final out = StringBuffer(
      '# $projectName — Requirements\n\nRevision $revision\n\n',
    );
    if (requirements.isEmpty) {
      out.writeln('No structured requirements recorded.');
    }
    for (final r in requirements) {
      out.writeln(
        '## ${r.id}: ${r.title}\n\nAcceptance criteria:\n${r.acceptance}\n',
      );
      for (final criterion in r.criteria) {
        out.writeln('Criterion ${criterion.id}: ${criterion.text}');
        out.writeln(
          'Verification rule: ${criterion.verificationRule.name}; verdict requires saved exact check evidence.',
        );
        out.writeln(
          'Mapped checks: ${criterion.checkIds.isEmpty ? "none" : criterion.checkIds.join(", ")}; acceptance not verified.',
        );
      }
      for (final check in r.checks) {
        out.writeln(
          '- Check ${check.id} (${check.type.name}): ${check.expectation} — no direct result recorded.',
        );
        if (check.target case final target?) {
          out.writeln(
            '  Target: Flutter test ${target.file}; exact name: ${target.name} (not executed).',
          );
        }
      }
      for (final t in tasks.where((t) => t.requirementId == r.id)) {
        out.writeln(
          '- [${t.status == TaskStatus.done ? 'x' : ' '}] ${t.id}: ${t.title} (${t.status.name}); dependencies: ${t.dependencies.isEmpty ? 'none' : t.dependencies.join(', ')}',
        );
      }
      out.writeln();
    }
    return out.toString();
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'plan_approval.dart';
import 'build_task.dart';

enum GeneratedSnapshotStatus { none, current, outdated, unknown }

enum SourceGenerationPhase { generated, verifying, ready, failed }

/// Verification evidence only; never a board completion or acceptance decision.
class BoardTaskVerification {
  const BoardTaskVerification({
    required this.boardTaskId,
    required this.passed,
    required this.total,
    required this.status,
  });
  final String boardTaskId;
  final int passed, total;
  final BuildTaskStatus status;
}

/// The only supported fixed-adapter policy; saved values cannot expand authority.
final class VerificationLimits {
  const VerificationLimits._();
  static const starter = VerificationLimits._();
  int get version => 1;
  int get commandTimeoutSeconds => 180;
  int get outputLimitBytes => 65536;
  int get maximumOperations => 4;

  Map<String, int> toJson() => {
    'version': version,
    'commandTimeoutSeconds': commandTimeoutSeconds,
    'outputLimitBytes': outputLimitBytes,
    'maximumOperations': maximumOperations,
  };

  factory VerificationLimits.fromJson(Object? value) {
    final expected = starter.toJson();
    if (value is! Map ||
        value.length != expected.length ||
        expected.entries.any(
          (entry) =>
              value[entry.key] is! int || value[entry.key] != entry.value,
        )) {
      throw const FormatException('Unsupported verification limits.');
    }
    return starter;
  }
}

class GenerationStep {
  const GenerationStep({
    required this.operation,
    required this.exitCode,
    required this.output,
    this.timedOut = false,
    this.outputLimitExceeded = false,
    this.cancelled = false,
  });
  final String operation, output;
  final int exitCode;
  final bool timedOut, outputLimitExceeded, cancelled;
  bool get succeeded =>
      exitCode == 0 && !timedOut && !outputLimitExceeded && !cancelled;
  Map<String, Object> toJson() => {
    'operation': operation,
    'exitCode': exitCode,
    'output': output,
    'timedOut': timedOut,
    'outputLimitExceeded': outputLimitExceeded,
    'cancelled': cancelled,
  };
  factory GenerationStep.fromJson(Map<String, dynamic> json) {
    final step = GenerationStep(
      operation: json['operation'] as String,
      exitCode: json['exitCode'] as int,
      output: json['output'] as String,
      timedOut: json['timedOut'] as bool,
      outputLimitExceeded: json['outputLimitExceeded'] as bool? ?? false,
      cancelled: json['cancelled'] as bool? ?? false,
    );
    if (!['resolve', 'analyze', 'test', 'build'].contains(step.operation) ||
        step.output.length > 65536) {
      throw const FormatException('Invalid generation step.');
    }
    return step;
  }
}

class GeneratedProject {
  GeneratedProject({
    required this.directory,
    required this.sdk,
    required this.python,
    required Map<String, String> sources,
    Map<String, String> outputs = const {},
    Map<String, String> resolution = const {},
    List<GenerationStep> steps = const [],
    this.phase = SourceGenerationPhase.generated,
    this.error = '',
    this.failedOperation = '',
    this.pendingOperation = '',
    this.checkpointVersion = 0,
    this.limits = VerificationLimits.starter,
    this.approval,
    this.confined = false,
    List<BuildTask>? tasks,
  }) : sources = Map.unmodifiable(sources),
       outputs = Map.unmodifiable(outputs),
       resolution = Map.unmodifiable(resolution),
       steps = List.unmodifiable(steps),
       tasks = tasks == null
           ? null
           : BuildTask.fromJson(tasks.map((t) => t.toJson()).toList()) {
    if (this.tasks != null && (approval == null || !approval!.approved)) {
      throw const FormatException('Structured tasks require an approved Plan.');
    }
  }
  final String directory, sdk, python, error;

  /// Model-written source always executes through the confined native runner.
  final bool confined;

  /// A task whose validation or runner threw; no command exit result is implied.
  final String failedOperation;

  /// Dispatch was authorized and may have started; no durable result yet.
  /// This marker never authorizes replay or implies successful execution.
  final String pendingOperation;

  /// Zero denotes legacy evidence without the resume protocol.
  final int checkpointVersion;

  final VerificationLimits limits;

  String? get resumeRefusal {
    if (checkpointVersion != 1) {
      return 'Legacy history has no safe resume checkpoint.';
    }
    if (phase != SourceGenerationPhase.verifying &&
        phase != SourceGenerationPhase.failed) {
      return 'There is no interrupted verification to resume.';
    }
    if (pendingOperation.isNotEmpty) {
      return 'A dispatched command has no saved result and may have changed files.';
    }
    if (steps.any((step) => !step.succeeded)) {
      return 'A failed or cancelled command requires an explicit full retry.';
    }
    if (steps.length >= (tasks ?? BuildTask.starter).length) {
      return 'All commands already completed; resume cannot replay them.';
    }
    return null;
  }

  final PlanApproval? approval;
  final List<BuildTask>? tasks;

  List<BoardTaskVerification> boardVerification({required bool active}) {
    final groups = <String, List<BuildTaskStatus>>{};
    for (final task in tasks ?? <BuildTask>[]) {
      final reference = task.boardTaskId;
      if (reference != null) {
        (groups[reference] ??= []).add(taskStatus(task, active: active));
      }
    }
    return List.unmodifiable([
      for (final entry in groups.entries)
        BoardTaskVerification(
          boardTaskId: entry.key,
          passed: entry.value.where((s) => s == BuildTaskStatus.passed).length,
          total: entry.value.length,
          status: entry.value.every((s) => s == BuildTaskStatus.passed)
              ? BuildTaskStatus.passed
              : [
                  BuildTaskStatus.failed,
                  BuildTaskStatus.running,
                  BuildTaskStatus.interrupted,
                  BuildTaskStatus.blocked,
                  BuildTaskStatus.pending,
                ].firstWhere(entry.value.contains),
        ),
    ]);
  }

  BuildTaskStatus taskStatus(BuildTask task, {required bool active}) {
    final graph = tasks ?? BuildTask.starter;
    final index = graph.indexWhere(
      (t) => t.id == task.id && t.operation == task.operation,
    );
    if (index < 0) return BuildTaskStatus.blocked;
    if (index < steps.length) {
      final step = steps[index];
      return step.succeeded ? BuildTaskStatus.passed : BuildTaskStatus.failed;
    }
    if (task.operation.name == failedOperation) return BuildTaskStatus.failed;
    if (steps.any((s) => !s.succeeded) ||
        phase == SourceGenerationPhase.failed) {
      return BuildTaskStatus.blocked;
    }
    if (index == steps.length && phase == SourceGenerationPhase.verifying) {
      return active ? BuildTaskStatus.running : BuildTaskStatus.interrupted;
    }
    return BuildTaskStatus.pending;
  }

  final Map<String, String> sources, outputs, resolution;
  final List<GenerationStep> steps;
  final SourceGenerationPhase phase;
  GeneratedProject copy({
    PlanApproval? approval,
    List<BuildTask>? tasks,
    String? sdk,
    String? python,
    String? failedOperation,
    String? pendingOperation,
    int? checkpointVersion,
    List<GenerationStep>? steps,
    Map<String, String>? outputs,
    Map<String, String>? resolution,
    SourceGenerationPhase? phase,
    String error = '',
  }) => GeneratedProject(
    directory: directory,
    confined: confined,
    approval: approval ?? this.approval,
    tasks: tasks ?? this.tasks,
    sdk: sdk ?? this.sdk,
    python: python ?? this.python,
    sources: sources,
    outputs: outputs ?? this.outputs,
    resolution: resolution ?? this.resolution,
    steps: steps ?? this.steps,
    phase: phase ?? this.phase,
    error: error,
    failedOperation: failedOperation ?? this.failedOperation,
    pendingOperation: pendingOperation ?? this.pendingOperation,
    checkpointVersion: checkpointVersion ?? this.checkpointVersion,
    limits: limits,
  );
  Map<String, Object> toJson() => {
    'limits': limits.toJson(),
    if (confined) 'confinementVersion': 1,
    'directory': directory,
    'sdk': sdk,
    'python': python,
    'sources': sources,
    'outputs': outputs,
    'resolution': resolution,
    'steps': steps.map((s) => s.toJson()).toList(),
    'phase': phase.name,
    'error': error,
    if (failedOperation.isNotEmpty) 'failedOperation': failedOperation,
    if (pendingOperation.isNotEmpty) 'pendingOperation': pendingOperation,
    if (checkpointVersion != 0) 'checkpointVersion': checkpointVersion,
    if (approval != null) 'approval': approval!.toJson(),
    if (tasks != null) 'tasks': tasks!.map((t) => t.toJson()).toList(),
  };
  factory GeneratedProject.fromJson(Map<String, dynamic> json) {
    final result = GeneratedProject(
      // Earlier records used exactly this fixed policy implicitly.
      limits: json.containsKey('limits')
          ? VerificationLimits.fromJson(json['limits'])
          : VerificationLimits.starter,
      confined: json.containsKey('confinementVersion'),
      directory: json['directory'] as String,
      tasks: json.containsKey('tasks')
          ? BuildTask.fromJson(json['tasks'])
          : null,
      approval: json.containsKey('approval')
          ? PlanApproval.fromJson(
              Map<String, dynamic>.from(json['approval'] as Map),
            )
          : null,
      sdk: json['sdk'] as String,
      python: json['python'] as String,
      sources: Map<String, String>.from(json['sources'] as Map),
      outputs: Map<String, String>.from(json['outputs'] as Map),
      resolution: Map<String, String>.from(
        json['resolution'] as Map? ?? const {},
      ),
      steps: (json['steps'] as List)
          .map(
            (s) => GenerationStep.fromJson(Map<String, dynamic>.from(s as Map)),
          )
          .toList(),
      phase: SourceGenerationPhase.values.byName(json['phase'] as String),
      error: json['error'] as String,
      failedOperation: json['failedOperation'] as String? ?? '',
      pendingOperation: json['pendingOperation'] as String? ?? '',
      checkpointVersion: json['checkpointVersion'] as int? ?? 0,
    );
    if ((json.containsKey('confinementVersion') &&
            (json['confinementVersion'] is! int ||
                json['confinementVersion'] != 1)) ||
        (result.checkpointVersion != 0 && result.checkpointVersion != 1) ||
        (result.approval != null && !result.approval!.approved) ||
        result.directory.isEmpty ||
        result.sdk.isEmpty ||
        result.python.isEmpty ||
        result.sources.isEmpty ||
        [result.sources, result.outputs, result.resolution].any(
          (files) => files.entries.any(
            (entry) =>
                entry.key.isEmpty ||
                entry.key.startsWith('/') ||
                entry.key
                    .split('/')
                    .any((part) => part == '..' || part == '.') ||
                entry.key.contains('\\') ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value),
          ),
        ) ||
        result.steps.length > result.limits.maximumOperations) {
      throw const FormatException('Invalid generated project record.');
    }
    final operations = (result.tasks ?? BuildTask.starter)
        .map((t) => t.operation.name)
        .toList();
    for (var i = 0; i < result.steps.length; i++) {
      if (result.steps[i].operation != operations[i] ||
          (i > 0 && !result.steps[i - 1].succeeded)) {
        throw const FormatException('Invalid verification history order.');
      }
    }
    if (result.pendingOperation.isNotEmpty &&
        ((result.phase != SourceGenerationPhase.verifying &&
                result.phase != SourceGenerationPhase.failed) ||
            result.steps.length >= operations.length ||
            operations[result.steps.length] != result.pendingOperation ||
            result.steps.any((step) => !step.succeeded) ||
            (result.failedOperation.isNotEmpty &&
                result.failedOperation != result.pendingOperation))) {
      throw const FormatException('Invalid pending operation checkpoint.');
    }
    if (result.failedOperation.isNotEmpty &&
        (result.phase != SourceGenerationPhase.failed ||
            result.steps.length >= operations.length ||
            operations[result.steps.length] != result.failedOperation ||
            result.steps.any((step) => !step.succeeded))) {
      throw const FormatException('Invalid failed operation identity.');
    }
    if (result.phase == SourceGenerationPhase.ready &&
        (result.steps.length != result.limits.maximumOperations ||
            result.steps.any((step) => !step.succeeded) ||
            !result.outputs.containsKey('index.html') ||
            !result.outputs.containsKey('main.dart.js'))) {
      throw const FormatException(
        'A ready outcome requires successful verification and compiled output.',
      );
    }
    return result;
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

enum RunnerOperation {
  checkSources,
  resolveDependencies,
  compile,
  test,
  run,
  open,
  stop,
}

enum RunnerAvailability {
  available,
  unavailableHost,
  notApplicable,
  notImplemented,
}

class RunnerCapability {
  const RunnerCapability(this.availability, this.reason);
  final RunnerAvailability availability;
  final String reason;
  bool get canDispatch => availability == RunnerAvailability.available;
}

/// Discovery describes dispatch boundaries, never project readiness or success.
class ProjectRunnerDescriptor {
  ProjectRunnerDescriptor({
    required this.id,
    required this.version,
    required this.adapterId,
    required this.outputStack,
    required Map<RunnerOperation, RunnerCapability> operations,
  }) : operations = Map.unmodifiable(operations);

  final String id, version, adapterId, outputStack;
  final Map<RunnerOperation, RunnerCapability> operations;
  RunnerCapability capability(RunnerOperation operation) =>
      operations[operation]!;
}

import 'source_generation.dart';

enum CandidateFailureKind {
  invalidEvidence,
  unsupportedEvidence,
  uncertainExecution,
  interrupted,
  cancelled,
  timeout,
  outputLimit,
  dependencyFailure,
  sourceCheckFailure,
  terminated,
  runnerOrValidation,
  missingFailure,
}

/// Read-only triage of recorded checks. This grants no retry or write authority
/// and cannot establish that source code caused a nonzero command exit.
class CandidateFailure {
  const CandidateFailure._(this.kind, this.message, [this.step]);
  final CandidateFailureKind kind;
  final String message;
  final GenerationStep? step;

  static CandidateFailure? inspect(
    GeneratedProject candidate, {
    required bool active,
  }) {
    // Running progress is not a terminal failure or an interrupted session.
    if (active) return null;
    try {
      GeneratedProject.fromJson(candidate.toJson());
    } catch (_) {
      return const CandidateFailure._(
        CandidateFailureKind.invalidEvidence,
        'Verification evidence is inconsistent. Reopen the candidate and inspect '
        'the saved record before any repair.',
      );
    }
    if (candidate.phase == SourceGenerationPhase.ready ||
        candidate.phase == SourceGenerationPhase.generated) {
      return null;
    }
    if (!candidate.confined || candidate.checkpointVersion != 1) {
      return const CandidateFailure._(
        CandidateFailureKind.unsupportedEvidence,
        'Legacy or unconfined verification cannot supply a source repair '
        'diagnosis. Prepare a reviewed confined candidate.',
      );
    }
    if (candidate.pendingOperation.isNotEmpty) {
      return CandidateFailure._(
        CandidateFailureKind.uncertainExecution,
        '${candidate.pendingOperation} was dispatched without a saved result. '
        'It may have changed files; do not replay it automatically.',
      );
    }
    if (candidate.phase == SourceGenerationPhase.verifying) {
      return const CandidateFailure._(
        CandidateFailureKind.interrupted,
        'Verification was interrupted without a terminal outcome. '
        'No failed source check is established.',
      );
    }
    if (candidate.failedOperation.isNotEmpty) {
      return CandidateFailure._(
        CandidateFailureKind.runnerOrValidation,
        '${candidate.failedOperation} stopped during validation or runner setup. '
        'There is no command exit result for this operation. '
        'Inspect the verification error before changing source.',
      );
    }
    final step = candidate.steps.isEmpty ? null : candidate.steps.last;
    if (step == null || step.succeeded) {
      return const CandidateFailure._(
        CandidateFailureKind.missingFailure,
        'Verification stopped without a failed command result. '
        'Inspect checkpoint, output validation and storage errors; '
        'no source failure is established.',
      );
    }
    final identity = '${step.operation} exited ${step.exitCode}.';
    if (step.cancelled) {
      return CandidateFailure._(
        CandidateFailureKind.cancelled,
        '$identity Verification was cancelled; no automatic repair should start.',
        step,
      );
    }
    if (step.timedOut) {
      return CandidateFailure._(
        CandidateFailureKind.timeout,
        '$identity The command deadline was exceeded. Inspect resource and '
        'toolchain conditions before requesting source changes.',
        step,
      );
    }
    if (step.outputLimitExceeded) {
      return CandidateFailure._(
        CandidateFailureKind.outputLimit,
        '$identity The output limit was exceeded; diagnostics may be incomplete. '
        'Inspect the bounded output before requesting source changes.',
        step,
      );
    }
    if (step.exitCode < 0) {
      return CandidateFailure._(
        CandidateFailureKind.terminated,
        '$identity The process terminated without a normal failure exit. '
        'No source cause is established.',
        step,
      );
    }
    if (step.operation == 'resolve') {
      return CandidateFailure._(
        CandidateFailureKind.dependencyFailure,
        '$identity Offline dependency resolution failed. Inspect the installed '
        'SDK and cached packages; this is not a source-check diagnosis.',
        step,
      );
    }
    return CandidateFailure._(
      CandidateFailureKind.sourceCheckFailure,
      '$identity A source check returned a failure. Its output can inform a '
      'repair diagnosis, but a source cause is not established. '
      'Success still requires rerunning all candidate checks.',
      step,
    );
  }
}

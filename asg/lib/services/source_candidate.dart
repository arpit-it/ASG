import '../models/approved_source_proposal.dart';
import '../models/build_plan.dart';
import '../models/project.dart';
import '../models/source_generation.dart';
import 'approved_source_proposer.dart';
import 'application_store.dart';
import 'generation_input.dart';
import 'record_storage.dart';
import 'requirements_store.dart';
import 'source_candidate_stub.dart'
    if (dart.library.io) 'source_candidate_native.dart'
    as platform;

/// Prepares an unverified copy only. Does not execute, save or promote output.
/// Callers must obtain explicit consent for the selected candidate parent.
Future<GeneratedProject> prepareSourceCandidate({
  required StudioProject project,
  required GeneratedProject generated,
  required ApprovedSourceProposal evidence,
  required RecordStorage records,
  required String parent,
  required void Function() checkActive,
}) async {
  final proposer = ApprovedSourceProposer(records);
  void authorize() {
    checkActive();
    proposer.requireCurrent(project, evidence);
    if (GenerationInput(
          project,
          ApplicationStore(records).load(project).definition,
        ).compare(generated) !=
        GeneratedSnapshotStatus.current) {
      throw StateError(
        'Generated project does not match current project inputs.',
      );
    }
  }

  authorize();
  final tasks = BuildPlan.parse(
    evidence.approval.content,
    board: RequirementsStore(records).load(project.id),
  ).tasks;
  final candidate = await platform.prepareCandidateFiles(
    generated: generated,
    proposal: evidence.proposal,
    parent: parent,
    authorizeWrite: authorize,
  );
  authorize();
  return GeneratedProject(
    directory: candidate.directory,
    sdk: generated.sdk,
    python: generated.python,
    sources: candidate.sources,
    approval: evidence.approval,
    tasks: tasks,
  );
}

import '../models/source_edit_proposal.dart';
import '../models/source_generation.dart';

Future<GeneratedProject> prepareCandidateFiles({
  required GeneratedProject generated,
  required SourceEditProposal proposal,
  required String parent,
  required void Function() authorizeWrite,
}) async => throw UnsupportedError(
  'Source candidate preparation requires a native filesystem.',
);

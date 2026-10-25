import '../models/approved_source_proposal.dart';
import '../models/build_plan.dart';
import '../services/requirements_store.dart';
import '../models/project.dart';
import '../models/source_generation.dart';
import '../services/application_store.dart';
import '../services/approved_source_proposer.dart';
import '../services/generation_host.dart';
import '../services/generation_input.dart';
import '../services/record_storage.dart';
import '../services/source_generation_store.dart';
import 'base_controller.dart';

typedef CandidatePromotion = Future<Uri> Function(
  GeneratedProject candidate,
  GenerationHost host,
  void Function() authorize,
);

/// Owns confined candidate checks, never writes the working generation record.
class SourceCandidateController extends BaseController {
  SourceCandidateController({
    required this.project,
    required GeneratedProject candidate,
    required this.evidence,
    required this.records,
    required this.host,
    required this.publish,
    this.requireWorking,
  }) : _result = candidate,
       _store = SourceGenerationStore(
         records,
         prefix: 'studio.sourceCandidate.v1.',
       );
  final StudioProject project;
  final ApprovedSourceProposal evidence;
  final RecordStorage records;
  final GenerationHost host;
  final CandidatePromotion publish;
  final void Function()? requireWorking;
  final SourceGenerationStore _store;
  GeneratedProject _result;
  GeneratedProject get result => _result;
  bool _busy = false,
      _cancelled = false,
      _promoting = false,
      _transferred = false;
  bool get busy => _busy;
  bool get promoting => _promoting;
  bool get promoted => _transferred;
  String? _error;
  String? get error => _error;
  Uri? _preview;
  Uri? get preview => _preview;

  void _authorize() {
    if (isDisposed || _cancelled) {
      throw StateError('Candidate operation stopped.');
    }
    if (!_result.confined) {
      throw StateError('Unconfined candidate refused.');
    }
    requireWorking?.call();
    ApprovedSourceProposer(records).requireCurrent(project, evidence);
    if (_result.approval == null ||
        !_result.approval!.matches(evidence.approval) ||
        !BuildPlan.parse(
          evidence.approval.content,
          board: RequirementsStore(records).load(project.id),
        ).matchesTasks(_result.tasks)) {
      throw StateError(
        'Candidate does not match the reviewed approval/task graph.',
      );
    }
    if (GenerationInput(
          project,
          ApplicationStore(records).load(project).definition,
        ).compare(_result) !=
        GeneratedSnapshotStatus.current) {
      throw StateError('Candidate inputs no longer match the current project.');
    }
  }

  bool get canPromote {
    if (_busy || _transferred || _result.phase != SourceGenerationPhase.ready) {
      return false;
    }
    try {
      _authorize();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _progress(GeneratedProject value) async {
    _authorize();
    await _store.save(project.id, value);
    _authorize();
    _result = value;
    update();
  }

  Future<void> verify({required bool approved}) async {
    if (!approved || _busy || _transferred || isDisposed) return;
    _busy = true;
    _cancelled = false;
    _error = null;
    update();
    try {
      _authorize();
      final verified = await host.verify(_result, _progress);
      _authorize();
      _result = verified;
    } catch (error) {
      if (!isDisposed) {
        _error =
            'Candidate verification stopped; working output retained. $error';
        _result = _result.copy(
          phase: SourceGenerationPhase.failed,
          error: _error!,
        );
        // Retain real completed evidence, but do not invent a command outcome.
        try {
          await _store.save(project.id, _result);
        } catch (_) {
          _error = '$_error Candidate checkpoint could not be saved.';
        }
      }
    } finally {
      _busy = false;
      update();
    }
  }

  void cancel() {
    if (!_busy || _promoting || isDisposed) return;
    _cancelled = true;
    host.cancelVerification();
    update();
  }

  Future<bool> promote({required bool approved}) async {
    if (!approved || !canPromote || isDisposed) return false;
    _busy = true;
    _promoting = true;
    _error = null;
    update();
    try {
      _authorize();
      _preview = await publish(_result, host, _authorize);
      _transferred = true;
      return true;
    } catch (error) {
      if (!isDisposed) {
        _error = 'Promotion refused; working output retained. $error';
      }
      return false;
    } finally {
      _promoting = false;
      if (isDisposed && !_transferred) await host.dispose();
      _busy = false;
      update();
    }
  }

  @override
  void dispose() {
    if (!_transferred) {
      host.cancelVerification();
      // Publication owns the host until its durable commit resolves.
      if (!_promoting) host.dispose().catchError((Object _) {});
    }
    super.dispose();
  }
}

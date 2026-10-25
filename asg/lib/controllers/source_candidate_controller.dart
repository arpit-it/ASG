import '../models/approved_source_proposal.dart';
import '../models/build_plan.dart';
import '../models/candidate_failure.dart';
import '../models/candidate_verification_run.dart';
import '../services/candidate_verification_store.dart';
import '../services/requirements_store.dart';
import '../models/project.dart';
import '../models/source_generation.dart';
import '../services/application_store.dart';
import '../services/approved_source_proposer.dart';
import '../services/generation_host.dart';
import '../services/generation_input.dart';
import '../services/record_storage.dart';
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
  }) : _result = candidate {
    _refreshHistory();
  }
  final StudioProject project;
  final ApprovedSourceProposal evidence;
  final RecordStorage records;
  final GenerationHost host;
  final CandidatePromotion publish;
  final void Function()? requireWorking;
  CandidateVerificationStore? _activeStore;
  GeneratedProject? _unsavedObservation;
  List<CandidateVerificationRun> _history = const [];
  List<CandidateVerificationRun> get history => _history;
  String? _historyError;
  String? get historyError => _historyError;
  void _refreshHistory() {
    try {
      _history = CandidateVerificationStore(records, project.id).load().runs;
      _historyError = null;
    } catch (_) {
      _historyError =
          'Saved candidate check history is unreadable. '
          'Verification is blocked; retained records have not been replaced.';
    }
  }

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
  CandidateFailure? get failureDiagnosis =>
      CandidateFailure.inspect(_result, active: _busy || _transferred);
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
    // Exit observations must survive a late Stop/withdrawal. Pending dispatch
    // checkpoints still require current authority before they can unblock work.
    final observation =
        value.steps.length > _result.steps.length ||
        value.phase == SourceGenerationPhase.failed;
    if (!observation) _authorize();
    if (observation && !isDisposed) _unsavedObservation = value;
    await _activeStore!.checkpoint(value, observation ? () {} : _authorize);
    _unsavedObservation = null;
    if (!isDisposed) {
      _result = value;
      _refreshHistory();
      update();
    }
    _authorize();
  }

  Future<void> verify({required bool approved}) async {
    if (!approved || _busy || _transferred || isDisposed) return;
    _busy = true;
    _cancelled = false;
    _unsavedObservation = null;
    _error = null;
    update();
    try {
      _authorize();
      final store = CandidateVerificationStore(records, project.id);
      final initial = _result.copy(
        phase: SourceGenerationPhase.verifying,
        checkpointVersion: 1,
        steps: [],
        outputs: {},
        pendingOperation: '',
        failedOperation: '',
      );
      await store.start(initial, _authorize);
      _activeStore = store;
      _authorize();
      _result = initial;
      _refreshHistory();
      _authorize();
      final verified = await host.verify(_result, _progress);
      _authorize();
      await store.checkpoint(verified, _authorize, finished: true);
      _authorize();
      _result = verified;
    } catch (error) {
      if (!isDisposed) {
        _error =
            'Candidate verification stopped; working output retained. $error';
        _result = (_unsavedObservation ?? _result).copy(
          phase: SourceGenerationPhase.failed,
          error: _error!,
        );
        // Retain real completed evidence, but do not invent a command outcome.
        try {
          // Recording an observed stop grants no command or promotion authority.
          // CAS still prevents a superseded session from overwriting history.
          await _activeStore?.checkpoint(_result, () {}, finished: true);
        } catch (_) {
          _error = '$_error Candidate checkpoint could not be saved.';
        }
      }
    } finally {
      _activeStore = null;
      if (!isDisposed) _refreshHistory();
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

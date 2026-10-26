import 'dart:async';
import 'dart:convert';

import '../models/app_definition.dart';
import '../models/build_history_entry.dart';
import '../models/build_plan.dart';
import '../models/plan_approval.dart';
import '../models/project.dart';
import '../models/source_generation.dart';
import '../services/generation_host.dart';
import '../services/record_storage.dart';
import '../services/application_store.dart';
import '../services/plan_approval_store.dart';
import '../services/generation_input.dart';
import '../services/folder_picker.dart';
import '../services/source_generation_store.dart';
import '../services/runtime_setup_store.dart';
import '../services/requirements_store.dart';
import 'base_controller.dart';
import 'source_review_controller.dart';

class SourceGenerationController extends BaseController {
  SourceGenerationController({
    required this.project,
    required this.definition,
    required this.store,
    required GenerationHost host,
    // Preserve the public injection name while allowing promoted-host ownership.
    // ignore: prefer_initializing_formals
  }) : _host = host {
    try {
      _input = GenerationInput(project, definition);
      _result = store.load(project.id);
      _initialPython = RuntimeSetupStore(store.records).load().python;
    } catch (e) {
      _error =
          'Generation inputs, settings or history could not be read. It has not been overwritten. $e';
      _historyInvalid = true;
    }
  }
  final StudioProject project;
  final AppDefinition definition;
  final SourceGenerationStore store;
  GenerationHost _host;
  GenerationHost get host => _host;
  GenerationInput? _input;
  GeneratedSnapshotStatus get snapshotStatus =>
      _input?.compare(_result) ?? GeneratedSnapshotStatus.unknown;
  GeneratedProject? _result;
  GeneratedProject? get result => _result;
  List<BuildHistoryEntry> get buildHistory => store.history(project.id);

  String _initialPython = 'python3';
  String get initialPython => _result?.python ?? _initialPython;
  String? _error;
  String? get error => _error;
  bool _busy = false, _historyInvalid = false;
  bool get busy => _busy;
  bool _verifying = false;
  bool get verifying => _verifying;
  bool _stopRequested = false;
  bool get stopRequested => _stopRequested;
  void stopVerification() {
    if (!_verifying || _stopRequested || isDisposed) return;
    _stopRequested = true;
    host.cancelVerification();
    update();
  }

  bool get available =>
      host.supported && !_historyInvalid && project.type == 'Flutter';
  Uri? _preview;
  Uri? get preview => _preview;

  SourceReviewController? createSourceReview({
    FolderPicker? folderPicker,
    GenerationHost Function()? createCandidateHost,
  }) {
    final saved = _result;
    if (_busy || !available || saved == null || isDisposed) return null;
    return SourceReviewController(
      project: project,
      generated: saved,
      records: store.records,
      publishCandidate: (value, candidateHost, authorize) => promoteCandidate(
        value,
        candidateHost,
        authorize,
        expectedWorking: saved,
      ),
      folderPicker: folderPicker,
      createCandidateHost: createCandidateHost,
    );
  }

  Future<Uri> promoteCandidate(
    GeneratedProject candidate,
    GenerationHost candidateHost,
    void Function() authorize, {
    required GeneratedProject expectedWorking,
  }) async {
    if (_busy || isDisposed) throw StateError('Build session unavailable.');
    final records = store.records;
    if (records is! ConditionalRecordStorage) {
      throw UnsupportedError(
        'Atomic conditional storage is required for promotion.',
      );
    }
    final current = _result;
    if (current == null ||
        identical(candidateHost, _host) ||
        jsonEncode(current.toJson()) != jsonEncode(expectedWorking.toJson()) ||
        candidate.directory == current.directory ||
        !candidate.confined ||
        candidate.phase != SourceGenerationPhase.ready) {
      throw StateError('A separately verified candidate is required.');
    }
    GeneratedProject.fromJson(candidate.toJson());
    _busy = true;
    update();
    var committed = false;
    try {
      void check() {
        if (isDisposed) throw StateError('Build session closed.');
        authorize();
        _recheckPlan(candidate.approval!);
      }

      check();
      final generationKey = 'studio.generation.v1.${project.id}';
      final old = records.getString(generationKey);
      if (old == null ||
          jsonEncode(store.load(project.id)!.toJson()) !=
              jsonEncode(current.toJson())) {
        throw StateError('Working build changed. Reopen review.');
      }
      final expected = <String, String?>{
        for (final key in [
          generationKey,
          'studio.projects.v1',
          'studio.application.v1.${project.id}',
          'studio.requirements.v1.${project.id}',
          'studio.planApproval.v1.${project.id}',
          'studio.chat.v1.${project.id}',
        ])
          key: records.getString(key),
      };
      // Separate host: validating/starting the new preview cannot stop the old one.
      final uri = await candidateHost.startPreview(candidate);
      check();
      await records.commitRecords(
        expected: expected,
        updates: {
          generationKey: store.encodeUpdate(project.id, candidate),
          'studio.generationPrevious.v1.${project.id}': old,
        },
        authorize: check,
      );
      // The atomic commit is the publication point. No cancellable work follows.
      final previousHost = _host;
      _host = candidateHost;
      _result = candidate;
      _preview = uri;
      committed = true;
      if (isDisposed) {
        unawaited(candidateHost.dispose().catchError((Object _) {}));
      }
      unawaited(previousHost.dispose().catchError((Object _) {}));
      return uri;
    } finally {
      try {
        if (!committed) await candidateHost.stopPreview();
      } finally {
        _busy = false;
        update();
      }
    }
  }

  String get planStatus {
    try {
      final approval = _requirePlan();
      final plan = BuildPlan.parse(
        approval.content,
        board: RequirementsStore(store.records).load(project.id),
      );
      return 'Current saved plan approved. Build runs the fixed Flutter starter pipeline only.\nValidated tasks: ${plan.preview}\n\n${approval.content}';
    } catch (e) {
      return 'Build is locked. $e';
    }
  }

  PlanApproval _requirePlan() {
    final approval = PlanApprovalStore(store.records)
        .requireCurrentApproval(project);
    final saved = ApplicationStore(store.records).load(project);
    final savedInput = GenerationInput(project, saved.definition);
    if (savedInput.applicationJson != _input?.applicationJson) {
      throw StateError(
        'The saved prototype changed. Reopen Build with the current prototype '
        'and review a fresh Plan before generating.',
      );
    }
    return approval;
  }

  void _recheckPlan(PlanApproval started) {
    final current = _requirePlan();
    BuildPlan.parse(
      current.content,
      board: RequirementsStore(store.records).load(project.id),
    );
    if (!current.matches(started)) {
      throw StateError(
        'Plan approval changed during preparation. Review it before restarting Build.',
      );
    }
  }

  Future<void> _verificationProgress(
    GeneratedProject value,
    PlanApproval approval,
  ) async {
    try {
      _recheckPlan(approval);
    } catch (error) {
      // Keep actual completed command evidence, but never publish Ready after
      // consent changed. Throwing stops the host before its next operation.
      await _save(
        value.copy(
          phase: SourceGenerationPhase.failed,
          error: 'Plan approval changed during verification. $error',
        ),
      );
      rethrow;
    }
    if (_stopRequested) {
      await _save(
        value.copy(
          phase: SourceGenerationPhase.failed,
          error: 'Verification stopped by user. Existing files and completed results are retained.',
        ),
      );
      throw StateError('Verification stopped by user.');
    }
    await _save(value);
    if (_stopRequested) {
      await _save(
        value.copy(
          phase: SourceGenerationPhase.failed,
          error: 'Verification stopped by user. Existing files and completed results are retained.',
        ),
      );
      throw StateError('Verification stopped by user.');
    }
    // A durable write is an async boundary; consent can change while it waits.
    _recheckPlan(approval);
  }

  Future<String?> chooseDirectory(FolderPicker picker) async {
    if (_busy || !available || !picker.supported || isDisposed) return null;
    _busy = true;
    _error = null;
    update();
    try {
      final selected = await picker.pick();
      return isDisposed ? null : selected;
    } catch (e) {
      if (!isDisposed) _error = 'Directory could not be selected: $e';
      return null;
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> _save(GeneratedProject value) async {
    if (isDisposed) throw StateError('Generation screen closed.');
    await store.save(project.id, value);
    if (isDisposed) return;
    _result = value;
    update();
  }

  Future<void> _failure(GeneratedProject? active, Object error) async {
    if (isDisposed) return;
    _error = 'Generation stopped; existing files were preserved. $error';
    if (active == null) return;
    final latest = _result?.directory == active.directory ? _result! : active;
    try {
      await _save(
        latest.copy(phase: SourceGenerationPhase.failed, error: _error!),
      );
    } catch (_) {
      _error =
          '$_error The failed outcome could not be saved; previous durable history remains intact.';
    }
  }

  Future<bool> generate({
    required String parent,
    required String name,
    required String sdk,
    required String python,
    required bool approved,
  }) async {
    if (!approved || _busy || !available || isDisposed) return false;
    _busy = true;
    _error = null;
    update();
    GeneratedProject? active;
    try {
      final approval = _requirePlan();
      final plan = BuildPlan.parse(
        approval.content,
        board: RequirementsStore(store.records).load(project.id),
      );
      await host.stopPreview();
      _recheckPlan(approval);
      if (isDisposed) return false;
      _preview = null;
      active = (await host.generate(
        project: project,
        definition: definition,
        parent: parent,
        name: name,
        sdk: sdk,
        python: python,
        authorizeWrite: () {
          if (isDisposed) throw StateError('Generation screen closed.');
          _recheckPlan(approval);
        },
      )).copy(approval: approval, tasks: plan.tasks);
      if (isDisposed) return false;
      await _save(active);
      if (isDisposed) return false;
      _recheckPlan(approval);
      _stopRequested = false;
      _verifying = true;
      final verified = await host.verify(
        active,
        (value) => _verificationProgress(value, approval),
      );
      return !isDisposed &&
          !_stopRequested &&
          verified.phase == SourceGenerationPhase.ready;
    } catch (e) {
      await _failure(active, e);
      return false;
    } finally {
      _verifying = false;
      _busy = false;
      update();
    }
  }

  Future<bool> verifyAgain({
    required bool approved,
    String? sdk,
    String? python,
    bool resume = false,
  }) async {
    final current = _result?.copy(
      sdk: sdk == null || sdk.trim().isEmpty ? null : sdk.trim(),
      python: python == null || python.trim().isEmpty ? null : python.trim(),
    );
    if (!approved || _busy || !available || current == null || isDisposed) {
      return false;
    }
    _busy = true;
    _error = null;
    update();
    var verificationStarted = false;
    try {
      if (current.confined) {
        throw StateError(
          'Model-written working output is preserved. Reopen source review '
          'and prepare a separate candidate for further verification.',
        );
      }
      if (resume &&
          (current.resumeRefusal != null ||
              current.sdk != _result?.sdk ||
              current.python != _result?.python)) {
        throw StateError(
          'Resume refused. ${current.resumeRefusal ?? 'Use the saved toolchain unchanged.'}',
        );
      }
      final approval = _requirePlan();
      final plan = BuildPlan.parse(
        approval.content,
        board: RequirementsStore(store.records).load(project.id),
      );
      if (!plan.matchesTasks(current.tasks) ||
          current.approval == null ||
          !current.approval!.matches(approval) ||
          _input?.compare(current) != GeneratedSnapshotStatus.current) {
        throw StateError(
          'This saved build does not match the current approved plan and inputs. Generate a new folder after reviewing the current Plan. Legacy builds remain available for preview.',
        );
      }
      await host.stopPreview();
      _recheckPlan(approval);
      if (isDisposed) return false;
      _preview = null;
      verificationStarted = true;
      _stopRequested = false;
      _verifying = true;
      final verified = await host.verify(
        current,
        (value) => _verificationProgress(value, approval),
        resume: resume,
      );
      return !isDisposed &&
          !_stopRequested &&
          verified.phase == SourceGenerationPhase.ready;
    } catch (e) {
      if (verificationStarted) {
        await _failure(current, e);
      } else if (!isDisposed) {
        _error = 'Build did not start. $e';
      }
      return false;
    } finally {
      _verifying = false;
      _busy = false;
      update();
    }
  }

  Future<void> startPreview() async {
    final current = _result;
    if (_busy || !available || current == null || isDisposed) return;
    _busy = true;
    _error = null;
    update();
    try {
      final uri = await host.startPreview(current);
      if (isDisposed) {
        await host.stopPreview();
        return;
      }
      _preview = uri;
    } catch (e) {
      if (!isDisposed) _error = '$e';
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> openPreview() async {
    final uri = _preview;
    if (uri == null || _busy || isDisposed) return;
    try {
      await host.openPreview(uri);
    } catch (e) {
      _error = '$e';
      update();
    }
  }

  Future<void> stopPreview() async {
    await host.stopPreview();
    _preview = null;
    update();
  }

  @override
  void dispose() {
    unawaited(host.dispose().catchError((Object _) {}));
    super.dispose();
  }
}

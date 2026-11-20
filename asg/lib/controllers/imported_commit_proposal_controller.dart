// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_plan.dart';
import '../models/imported_commit_context.dart';
import '../models/imported_commit_proposal.dart';
import '../models/imported_commit_proposal_record.dart';
import '../models/project_inspection.dart';
import '../services/imported_commit_proposal_store.dart';
import 'base_controller.dart';

class ImportedCommitProposalController extends BaseController {
  ImportedCommitProposalController({
    required ProjectInspection inspection,
    required ImportedCommitContext this.context,
    required this.store,
  }) : inspection = inspection,
       root = inspection.root;
  ImportedCommitProposalController.history({
    required this.root,
    required this.store,
  }) : inspection = null,
       context = null;
  final String root;
  final ProjectInspection? inspection;
  final ImportedCommitContext? context;
  bool get historyOnly => context == null;
  final ImportedCommitProposalStore store;
  int _generation = 0;
  bool _busy = false, _ready = false, _stale = false;
  String? _error;
  ImportedPlan? _plan;
  ImportedCommitProposal? _proposal;
  Map<String, String?>? _inputs;
  ImportedCommitProposalRecord? _saved;
  String? _savedRaw, _historyError;
  ImportedCommitProposalRecord? get saved => _saved;
  String? get historyError => _historyError;
  bool get canSave =>
      canPreview &&
      store.writable &&
      _proposal != null &&
      !stale &&
      !(_saved?.proposal.matches(_proposal!) ?? false);

  bool get busy => _busy;
  bool get canPreview => !isDisposed && _ready && !_busy;
  String? get error => _error;
  ImportedPlan? get plan => _plan;
  ImportedCommitProposal? get proposal => _proposal;
  bool get stale {
    if (_stale || _proposal == null) return _stale;
    try {
      store.requireInputs(_inputs!);
      return false;
    } catch (_) {
      return true;
    }
  }

  void _alive(int generation) {
    if (isDisposed || generation != _generation) {
      throw StateError('Proposal review is no longer active.');
    }
  }

  void invalidateDraft() {
    if (isDisposed || _busy) return;
    _stale = _proposal != null;
    if (_ready) _error = null;
    update();
  }

  Future<void> load() async {
    if (isDisposed || _busy) return;
    final generation = ++_generation;
    _busy = true;
    _ready = false;
    _error = null;
    _stale = _proposal != null;
    update();
    try {
      _alive(generation);
      try {
        final history = store.history(root);
        await store.verify(history.inputs, () => _alive(generation));
        _alive(generation);
        _saved = history.record;
        _savedRaw = history.inputs[ImportedCommitProposalStore.key(root)];
        _historyError = null;
      } catch (_) {
        if (!isDisposed) _historyError = 'Saved comparison could not be reopened. Previously loaded comparison is retained; existing records have not been replaced.';
        rethrow;
      }
      if (historyOnly) return;
      final selection = store.read(inspection!, context!);
      if (selection.inputs[ImportedCommitProposalStore.key(root)] !=
          _savedRaw) {
        throw StateError('Saved comparison changed. Reload.');
      }
      await store.verify(selection.inputs, () => _alive(generation));
      _alive(generation);
      _plan = selection.plan;
      _inputs = selection.inputs;
      _ready = true;
    } catch (_) {
      if (!isDisposed) {
        _error = historyOnly
            ? 'Saved comparison could not be reopened. Retry reload; existing records have not been replaced.'
            : 'Current reviewed committed-source plan could not be loaded. Review source, requirements and plan, then reload.';
      }
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> preview(String path, String replacement) async {
    if (!canPreview) return;
    final generation = ++_generation;
    _busy = true;
    _error = null;
    _stale = _proposal != null;
    update();
    try {
      _alive(generation);
      store.read(inspection!, context!);
      await store.verify(_inputs!, () => _alive(generation));
      _alive(generation);
      final value = ImportedCommitProposal.create(
        context: context!,
        plan: _plan!,
        path: path,
        replacement: replacement,
      );
      store.requireInputs(_inputs!);
      _alive(generation);
      _proposal = value;
      _stale = false;
    } catch (e) {
      if (!isDisposed) {
        if (e is! FormatException) _ready = false;
        _error = 'Proposal could not be prepared. Keep a current reviewed committed-source plan and a changed selected file within 16 KiB and 500 lines. Reload if planning inputs changed.';
      }
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> save(ImportedCommitProposal expected) async {
    if (isDisposed || _busy) return;
    if (!canSave || !identical(expected, _proposal)) {
      _error = 'Comparison changed. Preview the current draft before saving.';
      update();
      return;
    }
    final generation = ++_generation;
    _busy = true;
    _error = null;
    update();
    try {
      _alive(generation);
      final record = ImportedCommitProposalRecord.create(
        context: context!,
        plan: _plan!,
        proposal: expected,
        recordedAt: DateTime.now().toUtc(),
      );
      await store.save(record, inspection!, _inputs!, () => _alive(generation));
      _alive(generation);
      final updated = Map<String, String?>.unmodifiable({
        ..._inputs!,
        ImportedCommitProposalStore.key(root): record.encode(),
      });
      store.requireInputs(updated);
      _inputs = updated;
      _saved = record;
      _savedRaw = record.encode();
      _historyError = null;
    } catch (_) {
      if (!isDisposed) {
        _error = 'Comparison could not be saved or confirmed. Draft and previous comparison are retained. Reload if saved inputs changed, then retry.';
        try {
          store.requireInputs(_inputs!);
        } catch (_) {
          _ready = false;
          _stale = true;
        }
      }
    } finally {
      _busy = false;
      update();
    }
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _generation++;
    super.dispose();
  }
}

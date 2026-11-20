// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_plan.dart';
import '../models/imported_source_context.dart';
import '../models/imported_source_proposal.dart';
import '../models/project_inspection.dart';
import '../services/imported_source_proposal_store.dart';
import 'base_controller.dart';

class ImportedSourceProposalController extends BaseController {
  ImportedSourceProposalController({
    required this.inspection,
    required this.context,
    required this.store,
  });
  final ProjectInspection inspection;
  final ImportedSourceContext context;
  final ImportedSourceProposalStore store;
  int _generation = 0;
  bool _busy = false, _ready = false, _stale = false;
  String? _error;
  ImportedPlan? _plan;
  ImportedSourceProposal? _proposal;
  Map<String, String?>? _inputs;
  bool get busy => _busy;
  bool get canPreview => !isDisposed && _ready && !_busy;
  String? get error => _error;
  ImportedPlan? get plan => _plan;
  ImportedSourceProposal? get proposal => _proposal;
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
      final selection = store.read(inspection, context);
      await store.verify(selection.inputs, () => _alive(generation));
      _alive(generation);
      _plan = selection.plan;
      _inputs = selection.inputs;
      _ready = true;
    } catch (_) {
      if (!isDisposed) _error = 'Current reviewed source plan could not be loaded. Review source, requirements and plan, then reload.';
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
      store.read(inspection, context);
      await store.verify(_inputs!, () => _alive(generation));
      _alive(generation);
      final value = ImportedSourceProposal.create(
        context: context,
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
        _error = 'Proposal could not be prepared. Keep a current reviewed source plan and a changed selected file within 16 KiB and 500 lines. Reload if planning inputs changed.';
      }
    } finally {
      _busy = false;
      update();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/html/html_source_proposal.dart';
import '../models/html/html_reference_report.dart';
import '../services/html/html_reference_inspector.dart';
import '../models/model_request_provenance.dart';
import '../models/project.dart';
import '../services/html/html_project_store.dart';
import '../services/html/html_source_proposer.dart';
import '../services/html/html_starter_store.dart';
import '../services/model_settings_store.dart';
import '../services/record_storage.dart';
import 'base_controller.dart';

/// Explicit review-only requests. No source reads, writes or execution authority.
class HtmlSourceReviewController extends BaseController {
  HtmlSourceReviewController({
    required this.project,
    required this.records,
    HtmlSourceProposer? proposer,
    Future<HtmlReferenceReport> Function(HtmlSourceProposal)? inspectReferences,
    this.requestDeadline = const Duration(seconds: 90),
  }) : assert(requestDeadline > Duration.zero),
       _proposer = proposer ?? HtmlSourceProposer(),
       _inspectReferences = inspectReferences ?? inspectHtmlReferences;

  final StudioProject project;
  final RecordStorage records;
  final HtmlSourceProposer _proposer;
  final Future<HtmlReferenceReport> Function(HtmlSourceProposal)
  _inspectReferences;
  final Duration requestDeadline;
  bool _busy = false, _revoked = false, _inspecting = false;
  bool get busy => _busy;
  String? _error;
  String? get error => _error;
  String _status = 'Request untrusted source for review. No files will change.';
  String get status => _status;
  HtmlSourceProposal? _proposal;
  ModelRequestProvenance? _provenance;
  HtmlReferenceReport? _references;
  HtmlReferenceReport? get references => proposal == null ? null : _references;
  Map<String, String?>? _snapshot;
  Future<void>? _cleanup;

  Map<String, String?> _capture() {
    HtmlProjectStore(records).resolve(project);
    return {
      for (final key in [
        HtmlProjectStore.projectsKey,
        HtmlStarterStore.key,
        'studio.requirements.v1.${project.id}',
        'studio.chat.v1.${project.id}',
        'studio.planApproval.v1.${project.id}',
      ])
        key: records.getString(key),
    };
  }

  void _requireCurrent() {
    if (isDisposed || _revoked) throw StateError('Review revoked.');
    final now = _capture();
    if (_snapshot == null ||
        now.entries.any((entry) => _snapshot![entry.key] != entry.value)) {
      throw StateError('Review inputs changed.');
    }
  }

  HtmlSourceProposal? get proposal {
    if (_proposal == null) return null;
    try {
      _requireCurrent();
      return _proposal;
    } catch (_) {
      return null;
    }
  }

  /// Export authority belongs only to this exact current, temporary proposal.
  void authorizeProposal(HtmlSourceProposal displayed) {
    _requireCurrent();
    if (_busy || !identical(displayed, _proposal)) {
      throw StateError('Source proposal changed.');
    }
  }

  bool get stale => _proposal != null && proposal == null;
  ModelRequestProvenance? get provenance =>
      proposal == null ? null : _provenance;

  Future<void> request(String instruction) async {
    if (isDisposed || _busy) return;
    if (instruction.trim().isEmpty || instruction.length > 8000) {
      _error = 'Enter 1–8000 instruction characters.';
      update();
      return;
    }
    _busy = true;
    _revoked = false;
    _cleanup = null;
    _proposal = null;
    _references = null;
    _provenance = null;
    _error = null;
    Timer? deadline;
    try {
      _snapshot = _capture();
      final config = ModelSettingsStore(records).load();
      config.endpoint;
      final provenance = ModelRequestProvenance(
        model: config.model,
        outputTokens: ModelRequestProvenance.sourceOutputTokens,
      )..validate();
      _status = 'Requesting HTML source for review…';
      update();
      // Progress listeners can revoke authority before inference dispatch.
      _requireCurrent();
      deadline = Timer(requestDeadline, () {
        if (!_busy || isDisposed || _revoked) return;
        stop();
        _status = _inspecting
            ? 'HTML diagnostics deadline reached. Waiting for analysis to settle. No files changed.'
            : 'Review deadline reached. Wait for transport cleanup before retrying.';
        update();
      });
      final value = await _proposer.propose(
        config: config,
        instruction: instruction,
      );
      _requireCurrent();
      _inspecting = true;
      _status = 'Inspecting HTML references…';
      update();
      _requireCurrent();
      final references = await _inspectReferences(value);
      _requireCurrent();
      _references = references;
      _proposal = value;
      _provenance = provenance;
      _status = 'Untrusted proposal ready for review. No files changed.';
    } catch (_) {
      if (!isDisposed && !_revoked) {
        _error = 'Review request failed or saved project context changed. Check local model settings and project records, then retry. No files changed.';
        _status = 'No current proposal available.';
      }
    } finally {
      deadline?.cancel();
      // A separately dispatched Stop cleanup may outlive the request itself.
      await _cleanup;
      if (_inspecting) {
        _inspecting = false;
        _status = _status.replaceFirst(
          'Waiting for analysis to settle.',
          'The analysis request has returned; result ignored.',
        );
      }
      _busy = false;
      update();
    }
  }

  void stop() {
    if (isDisposed || !_busy || _revoked) return;
    _revoked = true;
    _proposal = null;
    _status = _inspecting
        ? 'HTML diagnostics stopped. Waiting for analysis to settle. No files changed.'
        : 'Review stopped. Waiting for transport cleanup; server-side inference may continue.';
    // Assign before notifying: reentrant listeners cannot redispatch cleanup.
    _cleanup = _proposer.cancel().catchError((Object _) {
      if (!isDisposed) {
        _error = 'Transport cleanup failed. Result ignored; inspect local runtime activity before retrying. Server-side inference may continue.';
        update();
      }
    });
    update();
  }

  @override
  void dispose() {
    _revoked = true;
    unawaited(_proposer.cancel().catchError((Object _) {}));
    super.dispose();
  }
}

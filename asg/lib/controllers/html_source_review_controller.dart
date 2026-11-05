// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import '../models/html/html_source_proposal.dart';
import '../models/html/html_source_draft.dart';
import '../services/html/html_source_draft_store.dart';
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
       _inspectReferences = inspectReferences ?? inspectHtmlReferences {
    _readDraftState();
  }

  final StudioProject project;
  final RecordStorage records;
  final HtmlSourceProposer _proposer;
  final Future<HtmlReferenceReport> Function(HtmlSourceProposal)
  _inspectReferences;
  final Duration requestDeadline;
  bool _busy = false, _revoked = false, _inspecting = false;
  bool _locallyEdited = false;
  bool _saving = false;
  // Edit-only retry handle. It never authorizes export or preview, and exists
  // only while the same editor/context survives a diagnostics failure.
  HtmlSourceProposal? _retryEditBase;
  bool _savedDraftAvailable = false;
  bool get savedDraftAvailable => _savedDraftAvailable;
  String? _savedDraftError;
  String? get savedDraftError => _savedDraftError;
  HtmlSourceDraftStore get _drafts => HtmlSourceDraftStore(records, project.id);

  void _readDraftState() {
    try {
      _savedDraftAvailable = _drafts.load() != null;
      _savedDraftError = null;
    } catch (_) {
      _savedDraftAvailable = false;
      _savedDraftError = 'Saved HTML draft is unreadable. It has been preserved; saving cannot replace it.';
    }
  }

  Future<void> saveDraft() async {
    if (isDisposed || _busy) return;
    final displayed = proposal;
    if (displayed == null) return;
    _busy = true;
    _saving = true;
    _error = null;
    _status = 'Saving reviewed source draft…';
    void authorize() {
      _requireCurrent();
      if (!identical(displayed, _proposal)) throw StateError('Review changed.');
    }

    try {
      update();
      authorize();
      await _drafts.save(
        HtmlSourceDraft(
          projectId: project.id,
          contextDigest: HtmlSourceDraftStore.digest(_snapshot!),
          proposal: displayed,
          provenance: _provenance!,
          locallyEdited: _locallyEdited,
        ),
        context: _snapshot!,
        authorize: authorize,
      );
      authorize();
      _status = 'Source draft saved locally. Restoring requires matching project context and fresh diagnostics.';
    } catch (_) {
      if (!isDisposed && !_revoked) {
        _error = 'Draft save failed or context changed. Current source is retained; inspect the saved draft before retrying.';
        _status = 'Draft save did not publish success.';
      }
    } finally {
      _saving = false;
      _busy = false;
      if (!isDisposed) _readDraftState();
      update();
    }
  }

  Future<void> restoreDraft() async {
    if (isDisposed || _busy) return;
    HtmlSourceDraft draft;
    Map<String, String?> context;
    try {
      draft = _drafts.load()!;
      context = _capture();
      if (draft.contextDigest != HtmlSourceDraftStore.digest(context)) {
        throw StateError('Saved draft context changed.');
      }
    } catch (_) {
      _readDraftState();
      _error = 'Cannot restore this draft: it is missing, unreadable or its saved project context changed. Current source and saved bytes are preserved.';
      update();
      return;
    }
    // Retain source until replacement succeeds, without reviving old authority.
    final previous = proposal;
    final previousReferences = references;
    final previousProvenance = provenance;
    final previousEdited = _locallyEdited;
    _busy = true;
    _inspecting = true;
    _revoked = false;
    _retryEditBase = null;
    _snapshot = context;
    _proposal = null;
    _references = null;
    _provenance = null;
    _error = null;
    _cleanup = null;
    _status = 'Inspecting saved HTML source draft…';
    final timer = Timer(requestDeadline, () {
      if (isDisposed || !_busy || _revoked) return;
      stop();
      _status = 'HTML diagnostics deadline reached. Waiting for analysis to settle. No files changed.';
      update();
    });
    try {
      update();
      _requireCurrent();
      final report = await _inspectReferences(draft.proposal);
      _requireCurrent();
      _proposal = draft.proposal;
      _references = report;
      _provenance = draft.provenance;
      _locallyEdited = draft.locallyEdited;
      _status = 'Saved source draft restored for review. No approval, files or preview changed.';
    } catch (_) {
      if (!isDisposed && !_revoked) {
        _error = 'Draft diagnostics failed or project context changed. Saved bytes are retained; retry restoration.';
        try {
          _requireCurrent();
          if (previous != null) {
            _proposal = HtmlSourceProposal.decode(
              jsonEncode({
                'summary': previous.summary,
                'files': previous.files,
              }),
            );
            _references = previousReferences;
            _provenance = previousProvenance;
            _locallyEdited = previousEdited;
          }
        } catch (_) {
          // Retained source from a changed context cannot regain authority.
        }
        _status = _proposal == null ? 'No restored proposal available.' : 'Restoration failed. Current reviewed source is retained; saved draft unchanged.';
      }
    } finally {
      timer.cancel();
      await _cleanup;
      _inspecting = false;
      _busy = false;
      _status = _status.replaceFirst(
        'Waiting for analysis to settle.',
        'The analysis request has returned; result ignored.',
      );
      update();
    }
  }

  bool get locallyEdited => _locallyEdited;
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
    if (_proposal == null || _busy) return null;
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

  Future<void> request(
    String instruction, {
    HtmlSourceProposal? refinement,
  }) async {
    if (isDisposed || _busy) return;
    if (instruction.trim().isEmpty || instruction.length > 8000) {
      _error = 'Enter 1–8000 instruction characters.';
      update();
      return;
    }
    if (refinement != null) {
      try {
        authorizeProposal(refinement);
        HtmlSourceProposer.refinementContext(refinement);
      } catch (_) {
        _error = 'Cannot refine this review: source is stale or exceeds the 24000-byte JSON context limit. Current source is retained; shorten it with local edits or request replacement source.';
        update();
        return;
      }
    }
    // A failed replacement must not discard unsaved reviewed source. Capture
    // only currently authorized source; recovery creates a new review identity.
    final previous = proposal;
    final previousReferences = references;
    final previousProvenance = provenance;
    final previousEdited = _locallyEdited;
    _busy = true;
    _revoked = false;
    _cleanup = null;
    _retryEditBase = null;
    _proposal = null;
    _references = null;
    _provenance = null;
    _locallyEdited = false;
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
        refinement: refinement,
        onProgress: (receivedChunks) {
          _requireCurrent();
          _status =
              'Response chunks received: $receivedChunks. Waiting for complete source validation…';
          update();
          _requireCurrent();
        },
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
        try {
          _requireCurrent();
          if (previous != null) {
            _proposal = HtmlSourceProposal.decode(
              jsonEncode({
                'summary': previous.summary,
                'files': previous.files,
              }),
            );
            _references = previousReferences;
            _provenance = previousProvenance;
            _locallyEdited = previousEdited;
          }
        } catch (_) {
          // Stale context cannot regain source authority after failure.
        }
        _status = _proposal == null ? 'No current proposal available.' : 'Replacement failed. Previous reviewed source is retained; no files changed.';
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

  /// Valid edits replace review identity before asynchronous inspection. Existing
  /// exports/previews retain only the old object and immediately lose authority.
  Future<void> revise(
    HtmlSourceProposal displayed,
    Map<String, String> files,
  ) async {
    if (isDisposed || _busy) return;
    HtmlSourceProposal candidate;
    try {
      _requireCurrent();
      if (!identical(displayed, _retryEditBase)) {
        authorizeProposal(displayed);
      }
      candidate = HtmlSourceProposal.decode(
        jsonEncode({'summary': displayed.summary, 'files': files}),
      );
    } catch (_) {
      _error = 'Edits are invalid or this review is stale. Keep nonempty HTML/CSS, optional nonempty JavaScript/SVG and the existing file/size limits.';
      update();
      return;
    }
    _busy = true;
    _inspecting = true;
    _proposal = null;
    _references = null;
    _error = null;
    _cleanup = null;
    _retryEditBase = null;
    _status = 'Inspecting edited HTML references…';
    final timer = Timer(requestDeadline, () {
      if (isDisposed || !_busy || _revoked) return;
      stop();
      _status = 'HTML diagnostics deadline reached. Waiting for analysis to settle. No files changed.';
      update();
    });
    try {
      update();
      _requireCurrent();
      final references = await _inspectReferences(candidate);
      _requireCurrent();
      _proposal = candidate;
      _references = references;
      _locallyEdited = true;
      _status = 'Locally edited proposal ready for review. No files changed.';
    } catch (_) {
      if (!isDisposed && !_revoked) {
        try {
          _requireCurrent();
          _retryEditBase = displayed;
        } catch (_) {
          // Changed inputs cannot regain edit, export or preview authority.
        }
        _error = _retryEditBase == null
            ? 'Edited-source inspection failed or project context changed. Request a new proposal. No files changed.'
            : 'Edited-source inspection failed. Your editor is retained; correct or retry Save edits for review. No files changed.';
        _status = 'No current proposal available.';
      }
    } finally {
      timer.cancel();
      await _cleanup;
      _inspecting = false;
      _busy = false;
      _status = _status.replaceFirst(
        'Waiting for analysis to settle.',
        'The analysis request has returned; result ignored.',
      );
      update();
    }
  }

  void stop() {
    if (isDisposed || !_busy || _revoked) return;
    _revoked = true;
    _retryEditBase = null;
    _proposal = null;
    if (_saving) {
      _status = 'Draft save stopped. An already-committed write may remain; inspect the saved draft after the write returns.';
      update();
      return;
    }
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
    _retryEditBase = null;
    unawaited(_proposer.cancel().catchError((Object _) {}));
    super.dispose();
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/agent_session.dart';
import '../models/published_task_evidence.dart';
import '../services/published_task_evidence_store.dart';
import 'base_controller.dart';

/// Owns a synchronous saved-record projection only; no host or work is started.
class PublishedTaskEvidenceController extends BaseController {
  PublishedTaskEvidenceController(
    this.store,
    this.selectedSession,
    this.runNumber,
  );
  final PublishedTaskEvidenceStore store;
  final AgentSession selectedSession;
  final int runNumber;
  PublishedTaskEvidence? _evidence;
  String? _error;
  PublishedTaskEvidence? get evidence => _evidence;
  String? get error => _error;
  void load() {
    if (isDisposed) return;
    _evidence = null;
    _error = null;
    try {
      final value = store.load(selectedSession, runNumber);
      if (!isDisposed) _evidence = value;
    } catch (_) {
      if (!isDisposed) _error = 'Published task evidence is unavailable for this saved selection. Check its publication, working output, session, Plan and saved inputs. Existing history is retained; another run is not selected automatically.';
    }
    update();
  }
}

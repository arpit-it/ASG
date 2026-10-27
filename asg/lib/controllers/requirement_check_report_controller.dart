// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project.dart';
import '../models/artifact_inspection.dart';
import '../models/requirement_check_report.dart';
import '../services/requirement_artifact_inspector.dart';
import '../services/requirement_check_report_store.dart';
import 'base_controller.dart';

class RequirementCheckReportController extends BaseController {
  RequirementCheckReportController(
    this.project,
    this.store, {
    ArtifactInspector? inspector,
    DateTime Function()? clock,
  }) : _inspector = inspector ?? RequirementArtifactInspector(),
       _clock = clock ?? DateTime.now;
  final ArtifactInspector _inspector;
  final DateTime Function() _clock;
  final StudioProject project;
  final RequirementCheckReportStore store;
  RequirementCheckReport? _report;
  RequirementCheckReport? get report => _report;
  String? _error;
  String? get error => _error;
  bool _inspecting = false;
  bool get inspecting => _inspecting;
  RequirementArtifactObservation? _observation;
  ArtifactInspection? get inspection => _observation?.outcome;
  DateTime? get inspectedAt => _observation?.observedAt;
  String? get evidenceJson => _report?.evidenceWithInspection(_observation);
  String? _inspectionNotice;
  String? get inspectionNotice => _inspectionNotice;
  int _revision = 0;
  void load() {
    if (isDisposed) return;
    _revision++;
    _observation = null;
    _inspectionNotice = null;
    try {
      _report = store.load(project);
      _error = null;
    } catch (_) {
      _report = null;
      _error = 'Saved review evidence is unavailable or unreadable. Records have not been changed. Check saved project data, then reload.';
    }
    update();
  }

  Future<void> inspectArtifacts() async {
    if (isDisposed || _inspecting) return;
    _inspecting = true;
    // Always inspect the current durable pointer, rather than an old screen.
    load();
    if (isDisposed) return;
    final selected = _report;
    final saved = selected?.savedProject;
    if (selected == null || saved == null) {
      _inspecting = false;
      update();
      return;
    }
    final revision = _revision;
    update();
    try {
      if (isDisposed) return;
      ArtifactInspection outcome;
      try {
        outcome = await _inspector.inspectArtifacts(saved);
      } catch (_) {
        outcome = ArtifactInspection.unavailable;
      }
      final observedAt = _clock().toUtc();
      if (isDisposed || revision != _revision) return;
      final current = store.load(project);
      _report = current;
      if (current.snapshotFingerprint != selected.snapshotFingerprint) {
        _inspectionNotice = 'Saved evidence changed during inspection. Current evidence was reloaded; inspect again.';
      } else {
        _observation = RequirementArtifactObservation(outcome, observedAt);
      }
    } catch (_) {
      // A newly corrupt record must clear the formerly successful report.
      load();
    } finally {
      if (!isDisposed) {
        _inspecting = false;
        update();
      }
    }
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import '../models/html/html_source_check.dart';
import '../models/project.dart';
import '../services/conversation_store.dart';
import '../services/html/html_project_store.dart';
import '../services/html/html_starter_runner.dart';
import '../services/plan_approval_store.dart';
import '../services/record_storage.dart';
import 'base_controller.dart';

/// Runs only the first approved HTML operation. Never starts the preview or
/// marks board tasks complete. Every read boundary revalidates durable consent.
class HtmlPlanCheckController extends BaseController {
  HtmlPlanCheckController(this.project, this.records, this.runner);
  final StudioProject project;
  final RecordStorage records;
  final HtmlStarterRunner runner;
  bool _busy = false;
  int _generation = 0;
  HtmlSourceCheck? _result;
  String? _message;
  bool get busy => _busy;
  HtmlSourceCheck? get result => _result;
  String? get message => _message;
  bool get supported => runner.sourceChecker.supported;

  String _requireConsent() {
    final store = PlanApprovalStore(records);
    final messages = ConversationStore(records).load(project.id);
    if (!store.hasCurrentHtmlConsent(project, messages)) {
      throw StateError('Current HTML consent required.');
    }
    return jsonEncode(store.load(project.id)!.toJson());
  }

  Future<void> check() async {
    if (isDisposed || _busy) return;
    _busy = true;
    _result = null;
    _message = 'Checking approved HTML starter source identity…';
    final generation = ++_generation;
    Timer? deadline;
    update();
    try {
      if (!supported) throw UnsupportedError('Host unavailable.');
      final consent = _requireConsent();
      final starter = HtmlProjectStore(records).resolve(project);
      void authorize() {
        if (isDisposed ||
            generation != _generation ||
            _requireConsent() != consent) {
          throw StateError('HTML check authority revoked.');
        }
      }

      deadline = Timer(const Duration(seconds: 10), () {
        if (!isDisposed && generation == _generation && _busy) {
          stop();
          _message = 'Source check reached its 10-second deadline. Pending file IO must settle before retry; no files were changed.';
          update();
        }
      });
      final checked = await runner.checkSources(
        directory: starter.directory,
        input: starter.input,
        authorizeRead: authorize,
      );
      authorize();
      _result = checked;
      _message = 'Approved source identity check completed. Preview and full Plan execution remain unavailable. Board progress was not changed.';
    } catch (_) {
      if (!isDisposed && generation == _generation) {
        _message = supported
            ? 'Source check refused or failed. Review current saved Plan consent and original starter files, then retry. No preview started and no files or board progress changed.'
            : 'Approved HTML source checks require the macOS fixed-starter host.';
      }
    } finally {
      deadline?.cancel();
      _busy = false;
      update();
    }
  }

  void stop() {
    if (isDisposed || !_busy) return;
    _generation++;
    _result = null;
    _message = 'Source check stopped. Pending file IO must settle before retry; no files were changed.';
    update();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }
}

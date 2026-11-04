// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../../models/html/html_site_input.dart';
import '../../models/project.dart';
import '../conversation_store.dart';
import '../plan_approval_store.dart';
import '../record_storage.dart';
import 'html_preview.dart';
import 'html_project_store.dart';
import 'html_starter_runner.dart';

/// Consent-bound fixed HTML check→preview integration. Owns revocation across
/// Stop and pending reads; the caller owns deadlines and cleanup retry.
class HtmlPlanPreview implements HtmlPreview {
  HtmlPlanPreview(this.project, this.records, this.runner);
  final StudioProject project;
  final RecordStorage records;
  final HtmlStarterRunner runner;
  int _generation = 0;
  void Function()? _authority;

  @override
  bool get supported => runner.supported && runner.sourceChecker.supported;

  String _consent() {
    final store = PlanApprovalStore(records);
    if (!store.hasCurrentHtmlConsent(
      project,
      ConversationStore(records).load(project.id),
    )) {
      throw StateError('Current HTML Plan consent required.');
    }
    return jsonEncode(store.load(project.id)!.toJson());
  }

  @override
  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
    void Function()? authorizeRead,
  }) async {
    if (!supported) throw UnsupportedError('HTML host unavailable.');
    final consent = _consent();
    final starter = HtmlProjectStore(records).resolve(project);
    if (directory != starter.directory ||
        input.title != starter.input.title ||
        input.description != starter.input.description) {
      throw StateError('Original HTML starter required.');
    }
    final generation = ++_generation;
    void authorize() {
      if (generation != _generation || _consent() != consent) {
        throw StateError('HTML Plan preview authority revoked.');
      }
      authorizeRead?.call();
    }

    _authority = authorize;
    await runner.checkSources(
      directory: directory,
      input: input,
      authorizeRead: authorize,
    );
    authorize();
    return runner.start(
      directory: directory,
      input: input,
      authorizeRead: authorize,
    );
  }

  @override
  Future<void> open() async {
    final authorize = _authority;
    if (authorize == null) throw StateError('Start an approved preview first.');
    authorize();
    await runner.open();
    authorize();
  }

  @override
  Future<void> stop() {
    _generation++;
    _authority = null;
    return runner.stop();
  }
}

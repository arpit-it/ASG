// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../../models/html/html_site_input.dart';
import '../../models/html/html_runner_result.dart';
import '../../models/html/html_source_check.dart';
import '../../models/project_runner.dart';
import 'html_preview.dart';
import 'html_preview_factory.dart';
import 'html_site_template.dart';
import 'html_source_check.dart';

/// Registered fixed-starter runner. No command strings or edited code dispatch.
/// Controllers retain deadline, cancellation and lifecycle ownership.
class HtmlStarterRunner implements HtmlPreview {
  HtmlStarterRunner({HtmlSourceChecker? checker, HtmlPreview? preview})
    : sourceChecker = checker ?? createHtmlSourceChecker(),
      _preview = preview ?? createHtmlPreview();

  final HtmlSourceChecker sourceChecker;
  final HtmlPreview _preview;
  static const runnerId = 'asg-fixed-html';
  static const runnerVersion = '1.0.0';

  ProjectRunnerDescriptor get descriptor {
    RunnerCapability host(bool available, String reason) => RunnerCapability(
      available
          ? RunnerAvailability.available
          : RunnerAvailability.unavailableHost,
      available ? reason : 'Requires the macOS fixed-starter host.',
    );
    return ProjectRunnerDescriptor(
      id: runnerId,
      version: runnerVersion,
      adapterId: HtmlSiteTemplate.adapterId,
      outputStack: 'HTML',
      operations: {
        RunnerOperation.checkSources: host(
          sourceChecker.supported,
          'Read-only exact starter identity; no lint or syntax verdict.',
        ),
        RunnerOperation.resolveDependencies: const RunnerCapability(
          RunnerAvailability.notApplicable,
          'This fixed starter has only local assets and no package dependencies.',
        ),
        RunnerOperation.compile: const RunnerCapability(
          RunnerAvailability.notApplicable,
          'Static HTML has no compile step. This does not validate JavaScript.',
        ),
        RunnerOperation.test: const RunnerCapability(
          RunnerAvailability.notImplemented,
          'No project test runner is delivered. Browser acceptance is separate.',
        ),
        RunnerOperation.run: host(
          _preview.supported,
          'Serve an unchanged starter snapshot on an owned loopback preview.',
        ),
        RunnerOperation.open: host(
          _preview.supported,
          'Request the OS browser for the active preview; opening is not verified.',
        ),
        RunnerOperation.stop: const RunnerCapability(
          RunnerAvailability.available,
          'Stop the owned preview; retain exported files.',
        ),
      },
    );
  }

  /// Unsupported operations return a typed refusal before any external action.
  /// Required inputs and authority are checked before supported dispatch.
  Future<HtmlRunnerResult> execute(
    RunnerOperation operation, {
    String? directory,
    HtmlSiteInput? input,
    void Function()? authorizeRead,
  }) async {
    final capability = descriptor.capability(operation);
    if (!capability.canDispatch) {
      return HtmlRunnerResult(
        operation: operation,
        status: RunnerResultStatus.unsupported,
        detail: capability.reason,
      );
    }
    HtmlSourceCheck? checked;
    Uri? url;
    switch (operation) {
      case RunnerOperation.checkSources:
        if (directory == null || input == null || authorizeRead == null) {
          throw ArgumentError(
            'Source checks require a target and read authority.',
          );
        }
        authorizeRead();
        checked = await sourceChecker.check(
          directory: directory,
          input: input,
          authorizeRead: authorizeRead,
        );
        authorizeRead();
      case RunnerOperation.run:
        if (directory == null || input == null) {
          throw ArgumentError('Preview requires a target.');
        }
        authorizeRead?.call();
        url = await _preview.start(
          directory: directory,
          input: input,
          authorizeRead: authorizeRead,
        );
        try {
          authorizeRead?.call();
        } catch (_) {
          // Own cleanup even when a preview publishes after authority is lost.
          // A cleanup failure must propagate; callers must retry Stop.
          await _preview.stop();
          rethrow;
        }
      case RunnerOperation.open:
        await _preview.open();
      case RunnerOperation.stop:
        await _preview.stop();
      case RunnerOperation.resolveDependencies:
      case RunnerOperation.compile:
      case RunnerOperation.test:
        // These operations must remain refusals, never successful no-ops.
        throw StateError('Unsupported operation reached dispatch.');
    }
    return HtmlRunnerResult(
      operation: operation,
      status: RunnerResultStatus.completed,
      detail: capability.reason,
      sourceCheck: checked,
      previewUrl: url,
    );
  }

  Future<HtmlSourceCheck> checkSources({
    required String directory,
    required HtmlSiteInput input,
    required void Function() authorizeRead,
  }) async {
    final result = await execute(
      RunnerOperation.checkSources,
      directory: directory,
      input: input,
      authorizeRead: authorizeRead,
    );
    if (result.status == RunnerResultStatus.unsupported) {
      throw UnsupportedError(result.detail);
    }
    return result.sourceCheck!;
  }

  @override
  bool get supported => descriptor.capability(RunnerOperation.run).canDispatch;
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
    void Function()? authorizeRead,
  }) async {
    final result = await execute(
      RunnerOperation.run,
      directory: directory,
      input: input,
      authorizeRead: authorizeRead,
    );
    if (result.status == RunnerResultStatus.unsupported) {
      throw UnsupportedError(result.detail);
    }
    return result.previewUrl!;
  }

  @override
  Future<void> open() async {
    final result = await execute(RunnerOperation.open);
    if (result.status == RunnerResultStatus.unsupported) {
      throw UnsupportedError(result.detail);
    }
  }

  @override
  Future<void> stop() async {
    await execute(RunnerOperation.stop);
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/imported_dart_diagnostics_controller.dart';
import '../models/imported_dart_diagnostics.dart';

class ImportedDartDiagnosticsScreen extends StatefulWidget {
  const ImportedDartDiagnosticsScreen({super.key, required this.controller});
  final ImportedDartDiagnosticsController controller;
  @override
  State<ImportedDartDiagnosticsScreen> createState() =>
      _ImportedDartDiagnosticsScreenState();
}

class _ImportedDartDiagnosticsScreenState
    extends State<ImportedDartDiagnosticsScreen> {
  final _sdk = TextEditingController();
  ImportedDartDiagnosticsController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    unawaited(c.load());
  }

  @override
  void didUpdateWidget(covariant ImportedDartDiagnosticsScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, c)) {
      old.controller.dispose();
      _sdk.clear();
      unawaited(c.load());
    }
  }

  @override
  void dispose() {
    c.dispose();
    _sdk.dispose();
    super.dispose();
  }

  Future<void> _consent() async {
    final owner = c, request = c.request;
    if (request == null || !c.canDiagnose) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run isolated file diagnostics?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Analyze only ${request.selectedPath} using a private verified copy of Dart ${request.sdk.version}.',
              ),
              SelectableText('Reviewed SDK: ${request.sdk.root}'),
              const Text(
                'Only the saved replacement is staged with fixed package settings. Project configuration, hooks and commands are ignored. No dependency downloads or model requests. Both saved copies are rechecked and preserved.',
              ),
              const Text(
                'Missing imports produce incomplete evidence. A clean result does not verify, build, test or authorize execution of the project.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Run isolated diagnostics'),
          ),
        ],
      ),
    );
    if (!mounted || !identical(owner, c) || agreed != true) return;
    await owner.diagnose(request);
  }

  List<Widget> _result(
    ImportedDartDiagnosticsObservation value, {
    required bool current,
  }) => [
    const Divider(),
    Text(
      '${current ? 'Completed isolated diagnostics' : 'Historical isolated diagnostics'}: ${value.status.name}',
    ),
    SelectableText('Observed at: ${value.recordedAt.toIso8601String()}'),
    SelectableText('Diagnostics request SHA-256: ${value.requestDigest}'),
    if (identical(value, c.result) && c.resultRequest != null) ...[
      SelectableText('Observed SDK: ${c.resultRequest!.sdk.root}'),
      Text('Observed Dart version: ${c.resultRequest!.sdk.version}'),
      SelectableText(
        'Observed runtime SHA-256: ${c.resultRequest!.sdk.runtimeHash}',
      ),
      SelectableText(
        'Observed analyzer SHA-256: ${c.resultRequest!.sdk.analyzerHash}',
      ),
      SelectableText(
        'Observed libraries SHA-256: ${c.resultRequest!.sdk.libraryHash}',
      ),
    ],
    if (value.reason != null) Text('Unavailable reason: ${value.reason}'),
    if (value.status == ImportedDartDiagnosticsStatus.clean)
      const Text(
        'No findings in the isolated file. The project remains unverified.',
      ),
    if (value.status == ImportedDartDiagnosticsStatus.incomplete)
      const Text(
        'Imports are unresolved in isolation. This is incomplete evidence, not a project failure.',
      ),
    for (final d in value.diagnostics)
      SelectableText(
        '${d.severity} ${d.code} at ${d.line}:${d.column}: ${d.message}',
      ),
  ];
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Isolated Dart diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Review an installed Dart SDK, then explicitly consent to analyze the saved replacement as one isolated file. No project commands, configuration or hooks run.',
          ),
          const Text(
            'Analysis is bounded to one 16 KiB replacement, 100 findings and a short deadline. SDK review is limited to 2048 library files and 128 MiB. Results are dated evidence, never project verification or approval.',
          ),
          SelectableText('Selected replacement: ${c.comparison.selectedPath}'),
          SelectableText('Original copy: ${c.comparison.originalCopy}'),
          SelectableText('Proposed copy: ${c.comparison.proposedCopy}'),
          SelectableText('Comparison request SHA-256: ${c.comparison.digest}'),
          if (!c.supported)
            const Text(
              'Native diagnostics are unavailable on this platform. Saved histories remain readable.',
            ),
          if (c.busy) const LinearProgressIndicator(),
          if (c.error != null) SelectableText(c.error!),
          if (c.workerBlocked)
            const Text(
              'Another source worker owns cleanup. Wait for confirmed cleanup.',
            ),
          if (c.cleanupUncertain)
            const Text(
              'Worker cleanup is unconfirmed. Ownership remains held; new work is blocked.',
            ),
          TextField(
            controller: _sdk,
            enabled: c.canReview,
            decoration: const InputDecoration(
              labelText: 'Installed Dart SDK folder',
              hintText: '/path/to/dart-sdk',
            ),
            onChanged: (_) => c.clearReview(),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: c.canReview
                    ? () => unawaited(c.reviewSdk(_sdk.text))
                    : null,
                child: const Text('Review SDK identity'),
              ),
              FilledButton(
                onPressed: c.canDiagnose ? _consent : null,
                child: const Text('Review diagnostics consent'),
              ),
              if (c.canStop)
                FilledButton(
                  onPressed: c.stop,
                  child: const Text('Stop diagnostics'),
                ),
            ],
          ),
          if (c.request case final request?) ...[
            SelectableText('Reviewed SDK: ${request.sdk.root}'),
            Text('Dart version: ${request.sdk.version}'),
            SelectableText('Runtime SHA-256: ${request.sdk.runtimeHash}'),
            SelectableText('Analyzer SHA-256: ${request.sdk.analyzerHash}'),
            SelectableText(
              'Library manifest SHA-256: ${request.sdk.libraryHash}',
            ),
            Text(
              'SDK libraries: ${request.sdk.libraryFiles} files, ${request.sdk.libraryBytes} bytes',
            ),
            SelectableText('Reviewed request SHA-256: ${request.digest}'),
            const Text('Exact saved replacement:'),
            SelectableText(request.replacement),
          ],
          if (c.result case final result?)
            ..._result(result, current: c.resultCurrent),
          if (c.lastObserved case final previous?)
            if (!identical(previous, c.result))
              ..._result(previous, current: false),
          if (c.stale)
            const Text(
              'Saved inputs changed. Reopen and compare the copies again.',
            ),
          const Text(
            'Original source, both copies, saved journals and last working outputs are preserved.',
          ),
        ],
      ),
    ),
  );
}

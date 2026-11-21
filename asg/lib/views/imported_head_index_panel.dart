// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import '../controllers/imported_workfile_controller.dart';
import '../controllers/imported_head_index_controller.dart';
import '../models/imported_head_index_observation.dart';
import '../services/imported_head_index_host_factory.dart';
import '../services/imported_head_index_store.dart';
import '../services/record_storage.dart';

class ImportedHeadIndexPanel extends StatefulWidget {
  const ImportedHeadIndexPanel({
    super.key,
    required this.root,
    required this.records,
    required this.workfile,
    this.controller,
  });
  final String root;
  final RecordStorage records;
  final ImportedWorkfileController workfile;
  final ImportedHeadIndexController? controller;
  @override
  State<ImportedHeadIndexPanel> createState() => _ImportedHeadIndexPanelState();
}

class _ImportedHeadIndexPanelState extends State<ImportedHeadIndexPanel> {
  late ImportedHeadIndexController controller;
  ImportedHeadIndexController _create() =>
      widget.controller ??
      ImportedHeadIndexController(
        root: widget.root,
        store: ImportedHeadIndexStore(widget.records),
        host: createImportedHeadIndexHost(),
        workfile: widget.workfile,
      );
  @override
  void initState() {
    super.initState();
    controller = _create();
  }

  @override
  void didUpdateWidget(covariant ImportedHeadIndexPanel old) {
    super.didUpdateWidget(old);
    if (old.root != widget.root ||
        !identical(old.records, widget.records) ||
        !identical(old.workfile, widget.workfile) ||
        !identical(old.controller, widget.controller)) {
      final previous = controller;
      controller = _create();
      if (!identical(previous, controller)) previous.dispose();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    final owner = controller;
    final request = await owner.prepare();
    if (!mounted || !identical(owner, controller) || request == null) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Read declared HEAD object facts?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Read the declared HEAD/reference, direct loose commit/tree/blob objects, expected index and selected files using the packaged read-only helper. No Git, project, filter or model commands run. Files and app records are not changed.',
              ),
              SelectableText('Folder: ${request.root}'),
              SelectableText('Existing interpreter: ${request.python}'),
              for (final file in request.files) SelectableText(file.path),
              SelectableText('Expected index SHA-256: ${request.indexHash}'),
              const Text(
                'This initial read refuses packed-reference lookup, replacement or alternate stores and unsupported layouts. Object expansion and selected file reads are bounded. Literal matches do not authenticate the repository, establish filtered or untracked status, create an atomic snapshot, or grant commit permission.',
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
            child: const Text('Read declared objects'),
          ),
        ],
      ),
    );
    if (!mounted || !identical(owner, controller)) return;
    await owner.inspect(request, confirmed: agreed == true);
  }

  List<Widget> _result(
    ImportedHeadIndexObservation value, {
    required bool current,
  }) => [
    const Divider(),
    Text(
      current
          ? 'Completed declared-object read'
          : 'Previous declared-object read — historical',
    ),
    Text('Read at ${value.recordedAt.toIso8601String()}'),
    if (value.observed) ...[
      const Text(
        'Direct loose-object declarations only. Repository authentication, filtered, untracked and whole-repository state remain unverified.',
      ),
      for (final file in value.files)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(file.path),
              if (file.treeOid == null)
                const Text(
                  'No regular-file declaration at this path in the observed tree.',
                ),
              Text(
                'Index declaration: ${file.indexMatchesTree ? 'matches observed tree' : 'differs from observed tree'}',
              ),
              Text(
                'Working bytes: ${file.workingBytesMatchTree ? 'match observed tree' : 'differ from observed tree'}',
              ),
              Text(
                'Executable bit: ${file.workingExecutableMatchesTree ? 'matches observed tree' : 'differs from observed tree'}',
              ),
              if (file.treeOid != null)
                ExpansionTile(
                  title: const Text('Declared file identity'),
                  children: [
                    SelectableText('Tree blob label: ${file.treeOid}'),
                    Text('Declared mode: ${file.treeMode}'),
                  ],
                ),
            ],
          ),
        ),
      ExpansionTile(
        title: const Text('Declared-object fingerprints'),
        children: [
          SelectableText('Declared HEAD ID: ${value.headOid}'),
          if (value.declaredRef != null)
            SelectableText('Loose reference: ${value.declaredRef}'),
          SelectableText('Declared tree ID: ${value.treeOid}'),
          SelectableText('Index SHA-256: ${value.indexHash}'),
          SelectableText('Read request SHA-256: ${value.requestDigest}'),
          Text(
            '${value.objectCount} bounded objects · ${value.objectBytes} expanded bytes',
          ),
        ],
      ),
    ] else
      const Text(
        'No declared-object joins were accepted. Inputs, metadata, object bytes or layout changed, were unavailable, stopped or exceeded the read bounds.',
      ),
  ];
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Declared HEAD object facts',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'First complete a selected-file comparison. This separate read compares direct loose-object tree declarations with the reviewed index and working-file fingerprints. It does not verify whole-repository state or grant commit permission.',
            ),
            if (!controller.supported)
              const Text(
                'Declared-object reading is unavailable on this platform.',
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: controller.canPrepare ? _request : null,
                  child: const Text('Review declared-object read'),
                ),
                if (controller.canStop)
                  OutlinedButton(
                    onPressed: controller.cancel,
                    child: const Text('Stop declared-object read'),
                  ),
              ],
            ),
            if (controller.busy) const LinearProgressIndicator(),
            if (controller.stopping)
              const Text('Finishing declared-object cleanup…'),
            if (controller.workerBlocked)
              const Text(
                'Another source worker owns cleanup. Wait for confirmed cleanup.',
              ),
            if (controller.cleanupUncertain)
              const Text(
                'Worker cleanup is unconfirmed. Shared ownership remains held.',
              ),
            if (controller.error != null) SelectableText(controller.error!),
            if (controller.observation case final value?)
              ..._result(value, current: controller.observationCurrent),
            if (controller.lastObserved case final previous?)
              if (!identical(previous, controller.observation))
                ..._result(previous, current: false),
          ],
        ),
      ),
    ),
  );
}

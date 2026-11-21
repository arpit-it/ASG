// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import 'imported_workfile_panel.dart';

import '../controllers/imported_index_controller.dart';
import '../models/imported_index_observation.dart';
import '../services/imported_index_host_factory.dart';
import '../services/imported_index_store.dart';
import '../services/record_storage.dart';

class ImportedIndexPanel extends StatefulWidget {
  const ImportedIndexPanel({
    super.key,
    required this.root,
    required this.records,
    this.controller,
  });
  final String root;
  final RecordStorage records;
  final ImportedIndexController? controller;
  @override
  State<ImportedIndexPanel> createState() => _ImportedIndexPanelState();
}

class _ImportedIndexPanelState extends State<ImportedIndexPanel> {
  late ImportedIndexController controller;
  ImportedIndexController _create() =>
      widget.controller ??
      ImportedIndexController(
        root: widget.root,
        store: ImportedIndexStore(widget.records),
        host: createImportedIndexHost(),
      );
  @override
  void initState() {
    super.initState();
    controller = _create();
  }

  @override
  void didUpdateWidget(covariant ImportedIndexPanel old) {
    super.didUpdateWidget(old);
    if (old.root != widget.root ||
        !identical(old.records, widget.records) ||
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
        title: const Text('Read local index declarations?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Read the local index file using the packaged read-only helper. Git, project commands and model requests are not run. Files are not changed.',
              ),
              SelectableText('Folder: ${request.root}'),
              SelectableText('Existing interpreter: ${request.python}'),
              const Text(
                'Only a bounded supported format is decoded. Locks, changed metadata and unsupported layouts refuse the read. Index declarations do not verify working files, HEAD membership or permission to commit.',
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
            child: const Text('Read index'),
          ),
        ],
      ),
    );
    if (!mounted || !identical(owner, controller)) return;
    await owner.inspect(request, confirmed: agreed == true);
  }

  String _description(ImportedIndexObservation value) => switch (value.status) {
    ImportedIndexStatus.observed => 'Supported index declarations were observed. They do not establish repository or working-tree state.',
    ImportedIndexStatus.unsupported => 'This index format or metadata layout is outside the supported subset. No declarations were accepted.',
    ImportedIndexStatus.invalid => 'Index bytes were missing, corrupt or outside the read bounds. No declarations were accepted.',
    ImportedIndexStatus.changed =>
      'Index metadata or its lock changed. No declarations were accepted.',
    ImportedIndexStatus.unavailable =>
      'The index could not be read. No declarations were accepted.',
    ImportedIndexStatus.stopped =>
      'The index read stopped. No declarations were accepted.',
  };
  List<Widget> _observation(
    ImportedIndexObservation value, {
    required bool current,
  }) => [
    const Divider(),
    Text(current ? 'Completed index read' : 'Previous index read — historical'),
    Text(_description(value)),
    Text('Read at ${value.recordedAt.toIso8601String()}'),
    if (value.observed) ...[
      Text('${value.entries.length} declared regular-file entries'),
      if (value.optionalCaches.isNotEmpty)
        const Text(
          'Optional cache bytes were included in the fingerprint but were not interpreted.',
        ),
      ExpansionTile(
        title: const Text('Index read details'),
        children: [
          SelectableText('Index SHA-256: ${value.indexHash}'),
          Text('Index bytes: ${value.indexByteLength}'),
          SelectableText('Read request SHA-256: ${value.requestDigest}'),
          for (final entry in value.entries.take(50))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(entry.path),
                  SelectableText(
                    'Declared mode: ${entry.mode} · Object ID: ${entry.oid}',
                  ),
                ],
              ),
            ),
          if (value.entries.length > 50)
            Text('Showing 50 of ${value.entries.length} declarations.'),
        ],
      ),
    ],
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
              'Local index declarations',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Read-only index declarations. Working files and HEAD membership are not verified. No commit permission is granted.',
            ),
            if (!controller.supported)
              const Text(
                'Local index inspection is unavailable on this platform.',
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: controller.canPrepare ? _request : null,
                  child: const Text('Review index read'),
                ),
                if (controller.canStop)
                  OutlinedButton(
                    onPressed: controller.cancel,
                    child: const Text('Stop index read'),
                  ),
              ],
            ),
            if (controller.busy) const LinearProgressIndicator(),
            if (controller.stopping) const Text('Finishing read cleanup…'),
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
              ..._observation(value, current: controller.observationCurrent),
            if (controller.lastObserved case final previous?)
              if (!identical(previous, controller.observation))
                ..._observation(previous, current: false),
            ImportedWorkfilePanel(
              root: widget.root,
              records: widget.records,
              index: controller,
            ),
          ],
        ),
      ),
    ),
  );
}

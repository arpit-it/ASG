// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import '../controllers/imported_index_controller.dart';
import '../controllers/imported_workfile_controller.dart';
import '../models/imported_workfile_comparison.dart';
import '../services/imported_workfile_host_factory.dart';
import '../services/imported_workfile_store.dart';
import '../services/record_storage.dart';

class ImportedWorkfilePanel extends StatefulWidget {
  const ImportedWorkfilePanel({
    super.key,
    required this.root,
    required this.records,
    required this.index,
    this.controller,
  });
  final String root;
  final RecordStorage records;
  final ImportedIndexController index;
  final ImportedWorkfileController? controller;
  @override
  State<ImportedWorkfilePanel> createState() => _ImportedWorkfilePanelState();
}

class _ImportedWorkfilePanelState extends State<ImportedWorkfilePanel> {
  late ImportedWorkfileController controller;
  final paths = TextEditingController();
  ImportedWorkfileController _create() =>
      widget.controller ??
      ImportedWorkfileController(
        root: widget.root,
        store: ImportedWorkfileStore(widget.records),
        host: createImportedWorkfileHost(),
        index: widget.index,
      );
  @override
  void initState() {
    super.initState();
    controller = _create();
  }

  @override
  void didUpdateWidget(covariant ImportedWorkfilePanel old) {
    super.didUpdateWidget(old);
    if (old.root != widget.root ||
        !identical(old.records, widget.records) ||
        !identical(old.index, widget.index) ||
        !identical(old.controller, widget.controller)) {
      final previous = controller;
      controller = _create();
      if (!identical(previous, controller)) {
        previous.dispose();
        paths.clear();
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    paths.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    final owner = controller;
    final request = await owner.prepare(
      paths.text
          .split('\n')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList(),
    );
    if (!mounted || !identical(owner, controller) || request == null) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Compare selected working files?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Read only the selected regular files and the expected index using the packaged helper. No Git, filters, project commands or model requests run. Files and app records are not changed.',
              ),
              SelectableText('Folder: ${request.root}'),
              SelectableText('Existing interpreter: ${request.python}'),
              for (final file in request.files) SelectableText(file.path),
              SelectableText('Expected index SHA-256: ${request.indexHash}'),
              const Text(
                'Up to 32 KiB per file and 64 KiB total. Raw bytes and executable bits are compared separately. This does not verify filtered Git status, HEAD membership or the whole repository, and grants no commit permission.',
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
            child: const Text('Compare files'),
          ),
        ],
      ),
    );
    if (!mounted || !identical(owner, controller)) return;
    await owner.inspect(request, confirmed: agreed == true);
  }

  List<Widget> _result(
    ImportedWorkfileObservation value, {
    required bool current,
  }) => [
    const Divider(),
    Text(
      current
          ? 'Completed selected-file comparison'
          : 'Previous selected-file comparison — historical',
    ),
    Text('Read at ${value.recordedAt.toIso8601String()}'),
    if (value.observed) ...[
      const Text(
        'Literal comparisons only. Filters, HEAD membership and whole-repository state remain unknown.',
      ),
      for (final file in value.files)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(file.path),
              Text(
                'Raw bytes: ${file.rawBlobMatches ? 'match index declaration' : 'differ from index declaration'}',
              ),
              Text(
                'Executable bit: ${file.executableMatches ? 'matches index declaration' : 'differs from index declaration'}',
              ),
              Text('Working-file bytes: ${file.byteLength}'),
              ExpansionTile(
                title: const Text('Selected-file fingerprints'),
                children: [
                  SelectableText('Working-file SHA-256: ${file.hash}'),
                  SelectableText('Raw blob label: ${file.rawBlob}'),
                ],
              ),
            ],
          ),
        ),
      ExpansionTile(
        title: const Text('Comparison identity'),
        children: [
          SelectableText('Index SHA-256: ${value.indexHash}'),
          SelectableText('Read request SHA-256: ${value.requestDigest}'),
        ],
      ),
    ] else
      const Text(
        'No selected-file comparisons were accepted. Inputs were unsupported, changed, missing, stopped or outside the read bounds.',
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
              'Selected working-file comparison',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'First complete an index read. Select 1–4 declared lib/ or test/ Dart paths, one per line. This read does not grant permission to change or commit files.',
            ),
            if (!controller.supported)
              const Text(
                'Selected-file comparison is unavailable on this platform.',
              ),
            TextField(
              controller: paths,
              enabled: !controller.busy && !controller.confirming,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Indexed Dart paths',
                hintText: 'e.g. lib/main.dart',
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: controller.canPrepare ? _request : null,
                  child: const Text('Review selected-file read'),
                ),
                if (controller.canStop)
                  OutlinedButton(
                    onPressed: controller.cancel,
                    child: const Text('Stop file comparison'),
                  ),
              ],
            ),
            if (controller.busy) const LinearProgressIndicator(),
            if (controller.stopping)
              const Text('Finishing comparison cleanup…'),
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

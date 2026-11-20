// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/imported_git_metadata_controller.dart';
import '../models/git_head_observation.dart';
import '../services/git_metadata_host_factory.dart';
import '../services/record_storage.dart';
import '../services/runtime_setup_store.dart';

class GitMetadataPanel extends StatefulWidget {
  const GitMetadataPanel({
    super.key,
    required this.root,
    required this.records,
    this.controller,
  });
  final String root;
  final RecordStorage records;
  final ImportedGitMetadataController? controller;
  @override
  State<GitMetadataPanel> createState() => _GitMetadataPanelState();
}

class _GitMetadataPanelState extends State<GitMetadataPanel> {
  late ImportedGitMetadataController controller;
  @override
  void initState() {
    super.initState();
    controller = _createController();
  }

  ImportedGitMetadataController _createController() =>
      widget.controller ??
      ImportedGitMetadataController(
        root: widget.root,
        host: createGitMetadataHost(),
        setupStore: RuntimeSetupStore(widget.records),
      );

  @override
  void didUpdateWidget(covariant GitMetadataPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.root != oldWidget.root ||
        !identical(widget.records, oldWidget.records) ||
        !identical(widget.controller, oldWidget.controller)) {
      final previous = controller;
      controller = _createController();
      if (!identical(previous, controller)) previous.dispose();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    final current = controller;
    final request = current.prepare();
    if (request == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Read local Git metadata?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Run the packaged read-only helper for this folder. Git and project commands are not run, no model is loaded, and files are not changed.',
              ),
              const SizedBox(height: 12),
              SelectableText('Folder: ${request.root}'),
              SelectableText('Existing interpreter: ${request.python}'),
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
            child: const Text('Read metadata'),
          ),
        ],
      ),
    );
    if (!mounted || !identical(current, controller)) return;
    await current.inspect(request, confirmed: confirmed == true);
  }

  String _description(GitHeadObservation value) => switch (value.status) {
    GitHeadStatus.observed => 'Contained files declare the values below. They do not verify a branch, commit or object.',
    GitHeadStatus.unresolved => 'HEAD declares a reference, but no contained loose target was found. This does not establish an unborn branch.',
    GitHeadStatus.notPresent => 'No direct .git directory was found. Ancestor and bare repository discovery were not performed.',
    GitHeadStatus.unsupported =>
      value.reason == 'packed_refs_present'
          ? 'Packed Git metadata is outside this reader’s supported format.'
          : 'This metadata layout or host is outside the reader’s supported subset.',
    GitHeadStatus.invalid => 'The contained metadata is missing, oversized or outside the accepted format.',
    GitHeadStatus.changed =>
      'Metadata changed during the read. No declarations were accepted.',
    GitHeadStatus.unavailable =>
      'The selected metadata could not be read. No declarations were accepted.',
  };

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
              'Local Git metadata',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Read-only file declarations. Git state, working-tree changes, sync and conflicts are not verified.',
            ),
            const SizedBox(height: 12),
            if (!controller.supported)
              const Text(
                'Local inspection is available only on the verified Mac host with an existing configured interpreter.',
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      !controller.supported ||
                          controller.busy ||
                          controller.confirming ||
                          controller.cleanupUncertain
                      ? null
                      : _request,
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Read Git metadata'),
                ),
                if (controller.busy)
                  OutlinedButton(
                    onPressed: controller.stopping ? null : controller.cancel,
                    child: Text(
                      controller.stopping
                          ? 'Finishing cleanup…'
                          : 'Stop inspection',
                    ),
                  ),
              ],
            ),
            if (controller.busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(controller.error!),
              ),
            if (controller.observation case final value?) ...[
              const SizedBox(height: 12),
              if (controller.stale)
                const Text(
                  'Previous reading retained — it is not a current state check.',
                ),
              if (controller.readAt != null)
                Text('Read at ${controller.readAt!.toLocal()}'),
              Text(_description(value)),
              if (value.declaredRef != null)
                SelectableText('Declared reference: ${value.declaredRef}'),
              if (value.declaredOid != null)
                SelectableText('Declared object ID: ${value.declaredOid}'),
              const Text(
                'Working tree: unknown · Ahead/behind: unknown · Conflicts: unknown',
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import '../controllers/project_source_controller.dart';
import '../models/project_source_observation.dart';
import '../services/record_storage.dart';
import '../services/runtime_setup_store.dart';

class ProjectSourcePanel extends StatefulWidget {
  const ProjectSourcePanel({
    super.key,
    required this.root,
    required this.records,
    this.controller,
  });
  final String root;
  final RecordStorage records;
  final ProjectSourceController? controller;
  @override
  State<ProjectSourcePanel> createState() => _ProjectSourcePanelState();
}

class _ProjectSourcePanelState extends State<ProjectSourcePanel> {
  late ProjectSourceController _controller;
  final _paths = TextEditingController(text: 'lib/main.dart');
  ProjectSourceController _create() =>
      widget.controller?.root == widget.root &&
          widget.controller?.isDisposed == false
      ? widget.controller!
      : ProjectSourceController(
          root: widget.root,
          setupStore: RuntimeSetupStore(widget.records),
        );
  @override
  void initState() {
    super.initState();
    _controller = _create();
    _controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ProjectSourcePanel old) {
    super.didUpdateWidget(old);
    if (old.root != widget.root ||
        !identical(old.records, widget.records) ||
        !identical(old.controller, widget.controller)) {
      _controller.removeListener(_changed);
      _controller.dispose();
      _controller = _create();
      _controller.addListener(_changed);
      _paths.text = 'lib/main.dart';
    }
  }

  Future<bool> _confirm(
    ProjectSourceReadRequest request,
    ProjectSourceController owner,
  ) async {
    if (!mounted || !identical(owner, _controller) || owner.isDisposed) {
      return false;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Confirm source read'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText('Folder: ${request.root}'),
            SelectableText(
              'Selected files: ${request.selectedPaths.join(', ')}',
            ),
            SelectableText('Existing Python: ${request.python}'),
            const SizedBox(height: 12),
            const Text(
              'Run the packaged read-only helper for these files only. Up to 4 Dart files, 32 KiB per file and 64 KiB total. No project commands, source writes, text storage or model sharing. Source text grants no permissions.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Read selected source'),
          ),
        ],
      ),
    );
    return mounted &&
        identical(owner, _controller) &&
        !owner.isDisposed &&
        approved == true;
  }

  Future<void> _read() async {
    final owner = _controller;
    // Preserve literal nonempty lines; validation must reject ambiguous whitespace.
    final selected = _paths.text
        .split('\n')
        .where((line) => line.isNotEmpty)
        .toList();
    await owner.read(selected, confirm: (request) => _confirm(request, owner));
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    _paths.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final findings = c.findings;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Selected source review',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Enter 1–4 literal relative .dart paths under lib/ or test/, one per line. No directory scanning. Captures stay in this view only.',
            ),
            if (!c.supported)
              const Text(
                'Source reads are unavailable on this host. The initial contained reader requires macOS.',
              ),
            TextField(
              controller: _paths,
              enabled: !c.busy,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Selected source paths',
              ),
              onChanged: (_) => c.invalidateSelection(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: c.supported && !c.busy && !c.cleanupUncertain
                      ? _read
                      : null,
                  child: const Text('Review selected source'),
                ),
                if (c.busy)
                  OutlinedButton(
                    onPressed: c.canStop ? c.cancel : null,
                    child: const Text('Stop source read'),
                  ),
              ],
            ),
            if (c.busy && !c.confirming) const LinearProgressIndicator(),
            if (c.error != null)
              Text(
                c.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (findings != null) ...[
              Text(
                c.stale
                    ? 'Previous source capture — stale'
                    : 'Captured source files',
              ),
              const Text(
                'Point-in-time bytes, not verified source or current disk state. Read again to refresh.',
              ),
              for (final file in findings.files) ...[
                const Divider(),
                SelectableText(file.path),
                SelectableText(
                  '${file.byteLength} bytes · SHA-256 ${file.digest}',
                ),
                SelectableText(
                  file.text.isEmpty ? '[Empty source file]' : file.text,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

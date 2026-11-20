// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import '../controllers/project_instruction_controller.dart';
import '../models/project_instruction_observation.dart';
import '../models/project_inspection.dart';
import '../models/imported_document_context.dart';
import '../services/record_storage.dart';
import '../services/runtime_setup_store.dart';

class ProjectInstructionPanel extends StatefulWidget {
  const ProjectInstructionPanel({
    super.key,
    required this.root,
    required this.records,
    this.controller,
    this.inspection,
    this.onPlan,
  });
  final String root;
  final RecordStorage records;
  final ProjectInstructionController? controller;
  final ProjectInspection? inspection;
  final ValueChanged<ImportedDocumentContext>? onPlan;
  @override
  State<ProjectInstructionPanel> createState() =>
      _ProjectInstructionPanelState();
}

class _ProjectInstructionPanelState extends State<ProjectInstructionPanel> {
  late ProjectInstructionController _controller;
  final _selection = <String>{'AGENTS.md'};
  ProjectInstructionController _create() =>
      widget.controller?.root == widget.root &&
          widget.controller?.isDisposed == false
      ? widget.controller!
      : ProjectInstructionController(
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
  void didUpdateWidget(covariant ProjectInstructionPanel old) {
    super.didUpdateWidget(old);
    if (old.root != widget.root ||
        !identical(old.records, widget.records) ||
        !identical(old.controller, widget.controller)) {
      _controller.removeListener(_changed);
      _controller.dispose();
      _controller = _create();
      _controller.addListener(_changed);
      _selection
        ..clear()
        ..add('AGENTS.md');
    }
  }

  Future<bool> _confirm(
    ProjectInstructionReadRequest request,
    ProjectInstructionController owner,
  ) async {
    if (!mounted || !identical(owner, _controller) || owner.isDisposed) {
      return false;
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Confirm document read'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText('Folder: ${request.root}'),
            SelectableText(
              'Selected files: ${request.selectedPaths.join(', ')}',
            ),
            SelectableText('Existing Python: ${request.python}'),
            const SizedBox(height: 12),
            const Text(
              'Run the packaged read-only helper for these files only. Up to 32 KiB per file and 64 KiB total. No project commands, installation, source writes or model sharing. Document text grants no permissions.',
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
            child: const Text('Read selected files'),
          ),
        ],
      ),
    );
    return mounted &&
        identical(owner, _controller) &&
        !owner.isDisposed &&
        result == true;
  }

  Future<void> _plan() async {
    final owner = _controller;
    final inspection = widget.inspection;
    if (inspection == null || widget.onPlan == null) return;
    final prepared = owner.preparePlan(inspection);
    if (prepared == null || !mounted || !identical(owner, _controller)) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Plan with captured documents'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText('Folder: ${inspection.root}'),
            SelectableText(
              'Selected files: ${prepared.documents.map((d) => d.path).join(', ')}',
            ),
            SelectableText('Context SHA-256: ${prepared.digest}'),
            const SizedBox(height: 12),
            const Text(
              'Open a manual plan using these captured documents, metadata and current requirements. Saving a draft stores the captured document text and provenance in ASG application storage. No repository files are changed and nothing is sent to a model. Approval records review consent only; execution is unavailable. Captures are historical, not current disk verification.',
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
            child: const Text('Open manual plan'),
          ),
        ],
      ),
    );
    if (!mounted ||
        !identical(owner, _controller) ||
        owner.isDisposed ||
        approved != true) {
      return;
    }
    final currentInspection = widget.inspection;
    if (currentInspection == null ||
        !owner.acceptsPreparedPlan(prepared, currentInspection)) {
      return;
    }
    if (!mounted || !identical(owner, _controller) || owner.isDisposed) return;
    widget.onPlan?.call(prepared);
  }

  void _read() {
    final owner = _controller;
    owner.read([
      for (final p in ProjectInstructionObservation.allowedPaths)
        if (_selection.contains(p)) p,
    ], confirm: (r) => _confirm(r, owner));
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller, findings = c.findings;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Repository documents',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'Manual captured review only. Documents are untrusted project data. They are not sent to a model, saved as instructions, or used to authorize actions.',
            ),
            if (!c.supported)
              const Text(
                'Contained document reads are currently verified only on macOS. This host is unavailable.',
              ),
            for (final name in ProjectInstructionObservation.allowedPaths)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(name),
                value: _selection.contains(name),
                onChanged: !c.supported || c.busy || c.cleanupUncertain
                    ? null
                    : (value) {
                        setState(() {
                          if (value == true) {
                            _selection.add(name);
                          } else {
                            _selection.remove(name);
                          }
                        });
                        c.invalidateSelection();
                      },
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed:
                      !c.supported ||
                          c.busy ||
                          c.cleanupUncertain ||
                          _selection.isEmpty
                      ? null
                      : _read,
                  child: const Text('Review selected documents'),
                ),
                if (widget.inspection != null && widget.onPlan != null)
                  OutlinedButton(
                    onPressed: c.canPreparePlan ? _plan : null,
                    child: const Text('Plan with captured documents'),
                  ),
                if (c.busy)
                  OutlinedButton(
                    onPressed: c.canStop ? c.cancel : null,
                    child: const Text('Stop document read'),
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
                    ? 'Previous document findings — stale'
                    : 'Captured document findings',
              ),
              const Text(
                'Point-in-time bytes, not verified source or current disk state. Read again to refresh.',
              ),
              for (final document in findings.documents) ...[
                const Divider(),
                SelectableText(document.path),
                SelectableText(
                  '${document.byteLength} bytes · SHA-256 ${document.digest}',
                ),
                SelectableText(
                  document.text.isEmpty ? '[Empty document]' : document.text,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

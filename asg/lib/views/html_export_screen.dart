// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/html_export_controller.dart';

class HtmlExportScreen extends StatefulWidget {
  const HtmlExportScreen({super.key, required this.controller});
  final HtmlExportController controller;
  @override
  State<HtmlExportScreen> createState() => _HtmlExportScreenState();
}

class _HtmlExportScreenState extends State<HtmlExportScreen> {
  final title = TextEditingController();
  final description = TextEditingController();
  final folder = TextEditingController();
  HtmlExportController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    controller.preview.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.preview.removeListener(refresh);
    controller.dispose();
    title.dispose();
    description.dispose();
    folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final review = controller.review;
    final enabled =
        controller.supported && !controller.busy && !controller.picking;
    return Scaffold(
      appBar: AppBar(title: const Text('Export HTML starter')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Export editable HTML, CSS, JavaScript and local SVG files from a fixed responsive starter. Your text fills its title and description. After export, preview this unchanged starter locally on macOS. Leaving this screen stops the preview. This does not create an ASG project. Full HTML runner integration is planned.',
              ),
              if (!controller.supported)
                const Text(
                  'HTML source export requires macOS. This host is not supported.',
                ),
              const SizedBox(height: 20),
              TextField(
                controller: title,
                enabled: enabled,
                decoration: const InputDecoration(labelText: 'Site title'),
                onChanged: (value) => controller.edit(title: value),
              ),
              TextField(
                controller: description,
                enabled: enabled,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Site description',
                ),
                onChanged: (value) => controller.edit(description: value),
              ),
              TextField(
                controller: folder,
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: 'New folder name',
                  helperText: '3–51 lowercase letters, digits or underscores; start with a letter.',
                  helperMaxLines: 4,
                ),
                onChanged: (value) => controller.edit(folder: value),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: enabled ? controller.pickParent : null,
                icon: const Icon(Icons.folder_open),
                label: Text(
                  controller.picking
                      ? 'Choosing folder…'
                      : 'Choose parent folder',
                ),
              ),
              SelectableText(
                controller.parent.isEmpty
                    ? 'No parent folder selected'
                    : controller.parent,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: enabled ? controller.prepareReview : null,
                child: const Text('Review export'),
              ),
              if (review != null) ...[
                const SizedBox(height: 20),
                const Text(
                  'Confirm this exact export',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SelectableText(
                  'Title: ${review.input.title}\nDescription: ${review.input.description}\nParent: ${review.parent}\nNew folder: ${review.folderName}',
                ),
                const Text(
                  'Files: index.html, styles.css, app.js, README.md and assets/mark.svg. Only a new folder is allowed. Existing paths are refused. Stop prevents later writes; a write already dispatched may finish. Partial files are retained on failure.',
                ),
                FilledButton(
                  onPressed: enabled ? () => controller.confirm(review) : null,
                  child: const Text('Confirm and export files'),
                ),
              ],
              if (controller.busy) ...[
                const LinearProgressIndicator(),
                Text(
                  controller.stopped
                      ? 'Stopping later writes; waiting for the current operation…'
                      : 'Exporting fixed starter files…',
                ),
                OutlinedButton(
                  onPressed: controller.stopped ? null : controller.stop,
                  child: const Text('Stop export'),
                ),
              ],
              if (controller.error != null) SelectableText(controller.error!),
              if (controller.exportedDirectory != null) ...[
                const Text(
                  'Source export complete. Full runner integration remains planned.',
                ),
                SelectableText(controller.exportedDirectory!),
                if (!controller.checker.supported)
                  const Text('Source identity checks require macOS.'),
                if (controller.checking) ...[
                  const LinearProgressIndicator(),
                  Text(
                    controller.checkStopped
                        ? 'Waiting for pending source reads to settle…'
                        : 'Checking exported file identity…',
                  ),
                ],
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed:
                          controller.checker.supported && !controller.checking
                          ? controller.checkExport
                          : null,
                      child: const Text('Check exported files'),
                    ),
                    if (controller.checking)
                      OutlinedButton(
                        onPressed: controller.checkStopped
                            ? null
                            : controller.stopCheck,
                        child: const Text('Stop check'),
                      ),
                  ],
                ),
                if (controller.sourceCheck != null)
                  SelectableText(controller.sourceCheck!.summary),
                const Text(
                  'Preview serves a validated snapshot. Editing exported files requires a different workflow; restarting refuses changes.',
                ),
                if (!controller.preview.supported)
                  const Text('Fixed HTML preview requires macOS.'),
                if (controller.preview.starting || controller.preview.stopping)
                  const LinearProgressIndicator(),
                if (controller.preview.starting)
                  const Text('Validating files and starting local preview…'),
                if (controller.preview.stopping)
                  const Text('Stopping local preview…'),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed:
                          controller.preview.supported &&
                              !controller.preview.busy &&
                              !controller.preview.cleanupFailed &&
                              controller.preview.url == null
                          ? controller.startPreview
                          : null,
                      child: const Text('Start preview'),
                    ),
                    OutlinedButton(
                      onPressed:
                          controller.preview.url != null &&
                              !controller.preview.busy
                          ? controller.preview.open
                          : null,
                      child: Text(
                        controller.preview.opening
                            ? 'Opening browser…'
                            : 'Open in browser',
                      ),
                    ),
                    OutlinedButton(
                      onPressed:
                          !controller.preview.stopping &&
                              (controller.preview.url != null ||
                                  controller.preview.starting ||
                                  controller.preview.cleanupFailed)
                          ? controller.preview.stop
                          : null,
                      child: const Text('Stop preview'),
                    ),
                  ],
                ),
                if (controller.preview.url != null)
                  SelectableText(controller.preview.url.toString()),
              ],
              if (controller.exportedDirectory == null &&
                  controller.preview.cleanupFailed)
                OutlinedButton(
                  onPressed: controller.preview.stopping
                      ? null
                      : controller.preview.stop,
                  child: const Text('Retry Stop preview'),
                ),
              if (controller.checkError != null)
                SelectableText(controller.checkError!),
              if (controller.preview.error != null)
                SelectableText(controller.preview.error!),
              if (controller.preview.notice != null)
                Text(controller.preview.notice!),
            ],
          ),
        ),
      ),
    );
  }
}

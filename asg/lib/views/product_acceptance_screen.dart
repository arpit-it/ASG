// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/product_acceptance_controller.dart';

class ProductAcceptanceScreen extends StatefulWidget {
  const ProductAcceptanceScreen({super.key});
  @override
  State<ProductAcceptanceScreen> createState() =>
      _ProductAcceptanceScreenState();
}

class _ProductAcceptanceScreenState extends State<ProductAcceptanceScreen> {
  final controller = ProductAcceptanceController();
  final input = TextEditingController();
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final report = controller.report;
    return Scaffold(
      appBar: AppBar(title: const Text('Product acceptance evidence')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Saved observations only. This viewer does not inspect current files, run checks, contact a model or establish product support. Report identities and results are supplied by its author. Even a saved passed cell is not a live health result.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: input,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Collector report JSON',
              border: OutlineInputBorder(),
            ),
          ),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                onPressed: () => controller.inspect(input.text),
                child: const Text('Inspect saved report'),
              ),
              TextButton(
                onPressed: () {
                  input.clear();
                  controller.clear();
                },
                child: const Text('Clear report'),
              ),
            ],
          ),
          if (controller.error != null)
            Text(
              controller.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (report == null)
            const Text(
              'No report loaded. Generate a report with tools/product_acceptance.py, then paste it above. Reports are session-only; reopen by pasting again.',
            ),
          if (report != null) ...[
            Text('Saved report generated: ${report.generatedAt}'),
            Text(
              '${report.cells.where((c) => c.status != 'passed').length} cells without a saved pass. Coverage is limited to cells in this report; omitted scenarios are not assessed.',
            ),
            ExpansionTile(
              title: const Text('Report identity and manifest'),
              children: [
                SelectableText(
                  'manifestSha256: ${report.manifestSha256}\n${report.identity.entries.map((e) => '${e.key}: ${e.value}').join('\n')}',
                ),
              ],
            ),
            for (final target in [
              'macos',
              'web',
              'android',
              'ios',
              'windows',
              'linux',
            ])
              ExpansionTile(
                title: Text('$target saved evidence'),
                children: [
                  for (final cell in report.cells.where(
                    (c) => c.target == target,
                  ))
                    ExpansionTile(
                      title: Text('${cell.scenarioId} / ${cell.checkId}'),
                      subtitle: Text(
                        '${cell.kind} · ${cell.requirementIds.join(', ')} · saved ${cell.status}',
                      ),
                      children: [
                        SelectableText(
                          cell.observedAt == null
                              ? 'No saved observation. ${cell.status == 'missing' ? 'Coverage missing.' : 'Target unconfigured/unavailable.'}'
                              : 'Observed: ${cell.observedAt}\nOriginal saved status: ${cell.savedStatus}\nSaved manifest SHA-256: ${cell.savedManifestSha256}\n${cell.savedIdentity!.entries.map((e) => '${e.key}: ${e.value}').join('\n')}\nArtifact SHA-256 digests: ${cell.artifactSha256.isEmpty ? 'none' : cell.artifactSha256.join(', ')}',
                        ),
                      ],
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import '../controllers/model_catalog_controller.dart';
import '../models/model_catalog.dart';

class ModelCatalogScreen extends StatefulWidget {
  const ModelCatalogScreen({super.key, required this.controller});
  final ModelCatalogController controller;
  @override
  State<ModelCatalogScreen> createState() => _ModelCatalogScreenState();
}

class _ModelCatalogScreenState extends State<ModelCatalogScreen> {
  ModelCatalogController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    controller.initialize();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = controller.hardware;
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a coding model')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Preferred models for this device',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(host.detail),
              Text(
                'Total memory: ${host.memoryBytes == null ? 'unknown' : memorySize(host.memoryBytes!)} · available estimate: ${host.availableBytes == null ? 'unknown' : memorySize(host.availableBytes!)}',
              ),
              const SizedBox(height: 12),
              const Text(
                'Check preferred models to find one suitable choice for Ask, planning, coding and review on this device. Selection only prepares the download form.',
              ),
              const ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('About this catalog and memory estimates'),
                children: [
                  Text(
                    'This curated list and public search are not exhaustive. Search returns up to 40 mlx-community matches. GitHub pages may contain documentation instead of model weights. Source checks read only public metadata; no project context is sent.',
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Memory estimates include all weights (including MoE), 25% overhead plus 4 GiB for runtime/cache, with 6 GiB reserved for OS/apps. Context and workloads can need more. Catalog checks do not verify live inference. A small owner-run comparison on one Mac favored Qwen3.8 coding correctness over Qwen3.5; speed varied. This is not a device-wide benchmark. No downloads or model switching happen here.',
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Preferred models only'),
                subtitle: const Text(
                  'One curated choice covering Ask, planning, coding and review. Requires checked compatibility and estimated headroom, or an exact pinned idle local load.',
                ),
                value: controller.preferredOnly,
                onChanged: controller.showPreferredOnly,
              ),
              if (controller.preferredOnly) ...[
                OutlinedButton(
                  onPressed: controller.busy
                      ? null
                      : controller.refreshPreferred,
                  child: const Text('Check preferred models'),
                ),
                const Text(
                  'ASG keeps an exact checked idle local model visible; otherwise it prioritizes Qwen3.8 27B, Qwen3.5 27B, then 9B when estimated memory fits. This is a curated policy, not a measured quality or speed guarantee. Other platforms require a compatible runtime connection; no local model is recommended here.',
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Search coding models',
                  border: OutlineInputBorder(),
                ),
                onChanged: controller.search,
              ),
              if (!controller.preferredOnly)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: controller.busy ? null : controller.discover,
                    icon: const Icon(Icons.search),
                    label: const Text('Search Hugging Face · MLX 4-bit'),
                  ),
                ),
              if (controller.searchError != null) Text(controller.searchError!),
              if (!controller.preferredOnly)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Only architectures enabled in ASG'),
                  subtitle: const Text(
                    'Unchecked sources remain visible until checked. Other architectures need a runtime adapter.',
                  ),
                  value: controller.compatibleOnly,
                  onChanged: controller.showCompatibleOnly,
                ),
              Text('${controller.entries.length} candidates shown'),
              if (controller.busy) const LinearProgressIndicator(),
              if (controller.entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    controller.preferredOnly
                        ? 'No preferred model yet. Check preferred models; unsupported hosts, unknown memory, memory pressure or failed source checks cannot produce a recommendation. Free memory and reopen this page to refresh device estimates, or use advanced discovery by turning off Preferred models only.'
                        : 'No matching candidates. Change the search or architecture filter.',
                  ),
                ),
              for (final entry in controller.entries) card(context, entry),
            ],
          ),
        ),
      ),
    );
  }

  Widget card(BuildContext context, ModelCatalogEntry entry) {
    final info = controller.metadata(entry),
        assessment = controller.assessment(entry);
    final error = controller.error(entry);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(entry.description),
            if (controller.preferredOnly)
              const Text('Roles: Ask · Planning · Coding · Review'),
            const SizedBox(height: 8),
            SelectableText(
              'Weights: https://huggingface.co/${entry.repository}',
            ),
            if (entry.github.isNotEmpty)
              SelectableText('Project/reference: ${entry.github}'),
            if (info != null) ...[
              const SizedBox(height: 8),
              Text(
                'Download: ${memorySize(info.downloadBytes)} · weight files: ${memorySize(info.weightBytes)} · license: ${info.license}',
              ),
              Text(
                'Architecture: ${info.architecture} · quantization: ${info.bits == 0 ? 'unknown' : '${info.bits}-bit'} · ${info.mlxFormat ? 'MLX layout' : 'format unconfirmed'}',
              ),
              SelectableText('Pinned revision: ${info.revision}'),
              Text(
                'Metadata checked: ${info.checkedAt.toIso8601String()} · live inference: unverified',
              ),
              if (assessment.estimatedBytes != null)
                Text(
                  'Estimated working memory: ${memorySize(assessment.estimatedBytes!)} + 6 GiB OS/apps',
                ),
            ],
            const SizedBox(height: 8),
            Text(assessment.detail),
            if (info != null)
              Text(
                'Hardware memory estimate: ${assessment.fitsMemory == null
                    ? 'unknown'
                    : assessment.fitsMemory!
                    ? 'within total budget'
                    : 'exceeds total budget'} · inference unverified',
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton(
                  key: ValueKey('check-${entry.repository}'),
                  onPressed: controller.busy
                      ? null
                      : () => controller.check(entry),
                  child: Text(
                    controller.checking == entry.repository
                        ? 'Checking source…'
                        : 'Check source',
                  ),
                ),
                FilledButton(
                  key: ValueKey('choose-${entry.repository}'),
                  onPressed: controller.busy || !assessment.canChoose
                      ? null
                      : () {
                          final choice = controller.choose(entry);
                          if (choice != null) Navigator.pop(context, choice);
                        },
                  child: const Text('Use in download form'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Selection only fills the form. Review destination, Python environment and size before pressing Download.',
            ),
          ],
        ),
      ),
    );
  }
}

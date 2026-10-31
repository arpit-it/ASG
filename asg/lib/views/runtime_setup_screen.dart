// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/runtime_setup_controller.dart';
import '../controllers/model_catalog_controller.dart';
import '../models/model_catalog.dart';
import 'model_catalog_screen.dart';
import 'model_download_panel.dart';
import '../models/local_model_config.dart';
import '../models/runtime_setup.dart';
import 'runtime_capability_panel.dart';

class RuntimeSetupScreen extends StatefulWidget {
  const RuntimeSetupScreen({
    super.key,
    required this.controller,
    this.createCatalog,
  });
  final RuntimeSetupController controller;
  final ModelCatalogController Function()? createCatalog;
  @override
  State<RuntimeSetupScreen> createState() => _RuntimeSetupScreenState();
}

class _RuntimeSetupScreenState extends State<RuntimeSetupScreen> {
  RuntimeSetupController get controller => widget.controller;
  final python = TextEditingController(),
      folder = TextEditingController(),
      repository = TextEditingController(),
      destination = TextEditingController(),
      revision = TextEditingController(),
      endpoint = TextEditingController(),
      model = TextEditingController();
  ModelSource source = ModelSource.local;
  RuntimeBackend backend = RuntimeBackend.auto;
  LocalModelConfig? lastConnection;
  @override
  void initState() {
    super.initState();
    controller.initialize();
    controller.addListener(refresh);
    final saved = controller.setup;
    python.text = saved.python;
    backend = saved.backend;
    folder.text = saved.modelPath;
    repository.text = saved.repository;
    destination.text = saved.downloadParent;
    revision.text = saved.revision;
    lastConnection = controller.connectionConfig;
    endpoint.text = controller.connectionConfig.baseUrl;
    model.text = controller.connectionConfig.model;
    python.addListener(controller.invalidateCapabilities);
  }

  void refresh() {
    if (!mounted) return;
    final current = controller.connectionConfig;
    if (current.baseUrl != lastConnection?.baseUrl ||
        current.model != lastConnection?.model) {
      endpoint.text = current.baseUrl;
      model.text = current.model;
      lastConnection = current;
    }
    setState(() {});
  }

  RuntimeSetup get values => RuntimeSetup(
    python: python.text.trim(),
    modelPath: folder.text.trim(),
    repository: repository.text.trim(),
    downloadParent: destination.text.trim(),
    revision: revision.text.trim(),
    backend: backend,
  );
  LocalModelConfig get connection =>
      LocalModelConfig(baseUrl: endpoint.text.trim(), model: model.text.trim());
  @override
  void dispose() {
    python.removeListener(controller.invalidateCapabilities);
    controller.removeListener(refresh);
    controller.dispose();
    for (final input in [
      python,
      folder,
      repository,
      destination,
      revision,
      endpoint,
      model,
    ]) {
      input.dispose();
    }
    super.dispose();
  }

  Widget field(
    TextEditingController input,
    String label, {
    String? hint,
    Widget? suffix,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: input,
      enabled: !controller.busy,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        suffixIcon: suffix,
      ),
    ),
  );
  Widget browse(TextEditingController target) => IconButton(
    tooltip: 'Choose folder',
    onPressed: controller.busy
        ? null
        : () async {
            final path = await controller.chooseDirectory();
            if (mounted && path != null) target.text = path;
          },
    icon: const Icon(Icons.folder_open),
  );
  Widget section(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Set up runtime')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            section('Local inference', [
              Row(
                children: [
                  Icon(
                    controller.health.ready
                        ? Icons.check_circle_outline
                        : Icons.power_settings_new,
                    color: controller.health.ready ? Colors.greenAccent : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      controller.health.ready
                          ? 'Runtime reports ready'
                          : 'Runtime not ready',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(controller.health.detail),
              const SizedBox(height: 8),
              Text(
                controller.health.loadedDevice == null
                    ? 'Loaded backend/device: unknown. No device or memory adequacy check.'
                    : 'Runtime reports loaded backend/device: ${controller.health.loadedDevice!.label}. Memory adequacy is not verified.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: controller.refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh status'),
                  ),
                  if (controller.host.ownsProcess)
                    OutlinedButton.icon(
                      onPressed: controller.stop,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop runtime'),
                    ),
                ],
              ),
              if (controller.health.ready && !controller.host.ownsProcess)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'This runtime was started outside this app. Connect below; stop it in its original terminal.',
                  ),
                ),
            ]),
            if (controller.host.supported) ...[
              section('1 · Select model files', [
                OutlinedButton.icon(
                  onPressed: controller.busy
                      ? null
                      : () async {
                          final choice =
                              await Navigator.push<ModelCatalogChoice>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ModelCatalogScreen(
                                    controller:
                                        widget.createCatalog?.call() ??
                                        ModelCatalogController(),
                                  ),
                                ),
                              );
                          if (!mounted || choice == null || controller.busy) {
                            return;
                          }
                          setState(() {
                            source = ModelSource.remote;
                            repository.text = choice.entry.repository;
                            revision.text = choice.metadata.revision;
                          });
                        },
                  icon: const Icon(Icons.manage_search),
                  label: const Text('Browse coding models for this computer'),
                ),
                const SizedBox(height: 16),
                SegmentedButton<ModelSource>(
                  segments: const [
                    ButtonSegment(
                      value: ModelSource.local,
                      icon: Icon(Icons.folder_outlined),
                      label: Text('Local files'),
                    ),
                    ButtonSegment(
                      value: ModelSource.remote,
                      icon: Icon(Icons.cloud_download_outlined),
                      label: Text('Repository'),
                    ),
                  ],
                  selected: {source},
                  onSelectionChanged: controller.busy
                      ? null
                      : (selection) =>
                            setState(() => source = selection.single),
                ),
                const SizedBox(height: 20),
                if (source == ModelSource.local) ...[
                  const Text(
                    'Use an existing downloaded checkpoint or a local Git repository. Select the folder containing config.json and all model weights, or a collection of model folders.',
                  ),
                  const SizedBox(height: 16),
                  field(
                    folder,
                    'Model folder / local repository',
                    suffix: browse(folder),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: controller.busy
                        ? null
                        : () => controller.inspect(folder.text.trim()),
                    icon: const Icon(Icons.search),
                    label: const Text('Find local models'),
                  ),
                ] else ...[
                  const Text(
                    'Download from a public Hugging Face model ID/URL or an HTTPS Git repository. No model is downloaded until you press Download. Large checkpoints can use many gigabytes; review the model license in its repository.',
                  ),
                  const SizedBox(height: 16),
                  field(
                    repository,
                    'Model repository',
                    hint: 'Qwen/Qwen3.5-9B or https://…/model.git',
                  ),
                  field(revision, 'Revision / branch'),
                  field(
                    destination,
                    'Download parent folder',
                    suffix: browse(destination),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: controller.busy
                        ? null
                        : () => controller.download(values),
                    icon: const Icon(Icons.download),
                    label: const Text('Download model & validate'),
                  ),
                  if (controller.transferControls)
                    ModelDownloadPanel(
                      progress: controller.downloadProgress,
                      busy: controller.busy,
                      onPause: controller.pauseDownload,
                      onStop: controller.stopDownload,
                      onResume: () => controller.download(values, resume: true),
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'Download starts a new repository-named folder. Resume reuses only a matching ASG partial transfer. Other existing folders are never overwritten. Hugging Face downloads fetch model artifacts; other Git hosts need actual committed weights, not LFS pointers.',
                  ),
                ],
                const SizedBox(height: 16),
                ...controller.candidates.map(
                  (candidate) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      candidate.supported ? Icons.memory : Icons.info_outline,
                    ),
                    title: Text(candidate.name),
                    subtitle: Text('${candidate.detail}\n${candidate.path}'),
                    selected: controller.selected?.path == candidate.path,
                    trailing: candidate.supported
                        ? Icon(
                            controller.selected?.path == candidate.path
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                          )
                        : const Text('Unsupported'),
                    onTap: candidate.supported && !controller.busy
                        ? () => controller.select(candidate)
                        : null,
                  ),
                ),
              ]),
              section('2 · Prepare & start', [
                const Text(
                  'Choose a Python environment with mlx-lm for fast local 4-bit Qwen3.5 inference on Apple Silicon. Legacy PyTorch/Transformers is also supported. Prepare checks the environment; only the legacy backend needs the Accelerate helper. Your existing Python packages are not replaced.',
                ),
                const SizedBox(height: 16),
                field(
                  python,
                  'Python executable',
                  hint: '/path/to/venv/bin/python',
                  suffix: IconButton(
                    tooltip: 'Choose Python executable',
                    onPressed: controller.busy
                        ? null
                        : () async {
                            final path = await controller.choosePython();
                            if (mounted && path != null) python.text = path;
                          },
                    icon: const Icon(Icons.folder_open),
                  ),
                ),
                DropdownButtonFormField<RuntimeBackend>(
                  initialValue: backend,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Backend for next launch',
                  ),
                  items: [
                    for (final value in RuntimeBackend.values)
                      DropdownMenuItem(value: value, child: Text(value.label)),
                  ],
                  onChanged: controller.busy
                      ? null
                      : (value) {
                          if (value != null) {
                            controller.invalidateCapabilities();
                            setState(() => backend = value);
                          }
                        },
                ),
                const SizedBox(height: 12),
                const Text(
                  'Auto keeps the legacy MLX-first dependency preference. Explicit choices never fall back to another backend. Torch/MPS needs compatible unquantized weights; MLX quantized weights cannot be reused by Torch. CPU/CUDA are unavailable. Selection does not verify dependencies, devices or model compatibility; launch validates them. Changing this choice leaves the active connection unchanged.',
                ),
                const SizedBox(height: 12),
                RuntimeCapabilityPanel(
                  report: controller.capabilities,
                  memory: controller.memory,
                  selected: controller.selected,
                  backend: backend,
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: controller.busy
                          ? null
                          : () => controller.discover(python.text),
                      child: const Text('Inspect capabilities'),
                    ),
                    OutlinedButton(
                      onPressed: controller.busy
                          ? null
                          : () => controller.saveSetup(values),
                      child: const Text('Save runtime setup'),
                    ),
                    OutlinedButton(
                      onPressed: controller.busy
                          ? null
                          : () => controller.prepare(python.text.trim()),
                      child: const Text('Prepare runtime helper'),
                    ),
                    FilledButton.icon(
                      onPressed:
                          controller.busy ||
                              controller.selected == null ||
                              controller.health.ready ||
                              controller.host.ownsProcess
                          ? null
                          : () => controller.start(values),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start selected model'),
                    ),
                  ],
                ),
              ]),
            ] else
              section('Model setup on your Mac', [
                const Text(
                  'Choosing files, downloading weights and starting Apple Metal inference are available in the macOS app. On Android Emulator, connect to the Mac using http://10.0.2.2:8765/v1. A phone cannot use the Mac’s localhost address.',
                ),
              ]),
            section('Connect project chat', [
              field(endpoint, 'Local API base URL'),
              field(model, 'Exact runtime model ID'),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: controller.busy
                        ? null
                        : () => controller.connect(connection),
                    child: const Text('Connect & save'),
                  ),
                  OutlinedButton(
                    onPressed: controller.busy
                        ? null
                        : () => controller.test(connection),
                    child: const Text('Test inference'),
                  ),
                  if (controller.testing)
                    OutlinedButton(
                      onPressed: controller.stopTest,
                      child: const Text('Stop test'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(RuntimeSetupController.requestLimits),
              const SizedBox(height: 12),
              const Text(
                'Connecting checks the runtime’s /health endpoint before saving the model for project chat.',
              ),
            ]),
            if (controller.busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(controller.status),
            ),
            if (controller.error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    controller.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            if (controller.logs.isNotEmpty)
              section('Setup log', [
                SelectableText(
                  controller.logs.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ]),
          ],
        ),
      ),
    ),
  );
}

import 'package:flutter/material.dart';

import '../controllers/source_generation_controller.dart';
import '../models/source_generation.dart';
import '../services/folder_picker.dart';

class SourceGenerationScreen extends StatefulWidget {
  const SourceGenerationScreen({
    super.key,
    required this.controller,
    this.picker,
  });
  final SourceGenerationController controller;
  final FolderPicker? picker;
  @override
  State<SourceGenerationScreen> createState() => _SourceGenerationScreenState();
}

class _SourceGenerationScreenState extends State<SourceGenerationScreen> {
  final parent = TextEditingController(),
      name = TextEditingController(text: 'generated_app');
  late final sdk = TextEditingController(text: controller.result?.sdk ?? '');
  late final python = TextEditingController(text: controller.initialPython);
  bool approved = false;
  SourceGenerationController get controller => widget.controller;
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
    for (final input in [parent, sdk, name, python]) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> pick(TextEditingController target) async {
    final selected = await controller.chooseDirectory(
      widget.picker ?? FolderPicker(),
    );
    if (mounted && selected != null) setState(() => target.text = selected);
  }

  Widget directory(TextEditingController input, String label) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: input,
          enabled: !controller.busy && controller.available,
          decoration: InputDecoration(labelText: label),
        ),
      ),
      IconButton(
        tooltip: 'Choose $label',
        onPressed: controller.busy || !controller.available
            ? null
            : () => pick(input),
        icon: const Icon(Icons.folder_open),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final result = controller.result;
    return PopScope(
      canPop: !controller.busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Generate Flutter app')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Create an independent Flutter web application',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              'Use the current saved prototype and reviewed requirements for ${controller.project.name}. A fixed MVC starter is written to a NEW folder, then checked, tested and built. This does not generate arbitrary model-written source or replace an existing app.',
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              title: const Text('Review generation input'),
              children: [
                SelectableText(controller.project.description),
                Text(
                  'Requested platforms: ${controller.project.platforms.join(', ')}. This starter exports Flutter web only.',
                ),
                Text(
                  'Current app: ${controller.definition.title} • ${controller.definition.theme}',
                ),
                for (final element in controller.definition.elements)
                  ListTile(
                    title: Text(element.label),
                    subtitle: Text(element.kind.name),
                  ),
              ],
            ),
            if (!controller.available)
              const Text(
                'Generation currently requires the macOS app, Flutter project type and readable history. Other platforms retain the in-app prototype.',
              ),
            directory(parent, 'Existing parent directory'),
            TextField(
              controller: name,
              enabled: !controller.busy && controller.available,
              decoration: const InputDecoration(
                labelText: 'New folder name (lowercase_with_underscores)',
              ),
            ),
            directory(sdk, 'Installed Flutter SDK directory'),
            TextField(
              controller: python,
              enabled: !controller.busy && controller.available,
              decoration: const InputDecoration(
                labelText: 'Installed Python 3 executable',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Approved operations: offline dependency resolution, Flutter analysis, tests, web build, and an optional loopback preview. Each command has a 3-minute deadline and bounded output. Missing cached SDK packages cause a failure; no package/model installation is performed. These trusted tools run with your host permissions, not in a security sandbox.',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I approve creating this new project and running the listed verification steps',
              ),
              value: approved,
              onChanged: controller.busy
                  ? null
                  : (value) => setState(() => approved = value ?? false),
            ),
            FilledButton.icon(
              onPressed: controller.busy || !controller.available || !approved
                  ? null
                  : () => controller.generate(
                      parent: parent.text.trim(),
                      name: name.text.trim(),
                      sdk: sdk.text.trim(),
                      python: python.text.trim(),
                      approved: approved,
                    ),
              icon: const Icon(Icons.code),
              label: const Text('Generate, test and build'),
            ),
            if (controller.busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const Text(
                'Working… saved outcomes appear below. Keep this screen open.',
              ),
            ],
            if (controller.error != null)
              SelectableText(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (result != null) ...[
              const Divider(height: 32),
              Text(
                'Saved outcome: ${result.phase.name}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              SelectableText(result.directory),
              if (result.phase == SourceGenerationPhase.verifying &&
                  !controller.busy)
                const Text(
                  'The previous run was interrupted. Retry verification of unchanged source; no existing files will be regenerated.',
                ),
              if (result.error.isNotEmpty) Text(result.error),
              for (final step in result.steps)
                ExpansionTile(
                  title: Text(
                    '${step.operation}: ${step.timedOut
                        ? 'timed out'
                        : step.exitCode == 0
                        ? 'passed'
                        : 'failed (${step.exitCode})'}',
                  ),
                  children: [SelectableText(step.output)],
                ),
              OutlinedButton(
                onPressed: controller.busy || !controller.available || !approved
                    ? null
                    : () => controller.verifyAgain(
                        approved: approved,
                        sdk: sdk.text,
                        python: python.text,
                      ),
                child: const Text('Retry verification (unchanged source only)'),
              ),
              if (result.phase == SourceGenerationPhase.ready)
                OutlinedButton(
                  onPressed: controller.busy || !controller.available
                      ? null
                      : controller.startPreview,
                  child: const Text('Start actual built preview'),
                ),
            ],
            if (controller.preview != null) ...[
              const Text(
                'Actual generated build served locally; this is separate from the in-app prototype. The server stops when this screen closes.',
              ),
              SelectableText(controller.preview.toString()),
              FilledButton(
                onPressed: controller.busy || !controller.available
                    ? null
                    : controller.openPreview,
                child: const Text('Open generated app in browser'),
              ),
              TextButton(
                onPressed: controller.busy || !controller.available
                    ? null
                    : controller.stopPreview,
                child: const Text('Stop preview'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

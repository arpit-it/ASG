// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../services/model_settings_store.dart';
import '../controllers/model_settings_controller.dart';

import '../models/local_model_config.dart';

class ModelSettings extends StatefulWidget {
  const ModelSettings({super.key, required this.store, this.inspectInventory});
  final ModelSettingsStore store;
  final Future<String> Function(LocalModelConfig)? inspectInventory;
  @override
  State<ModelSettings> createState() => _ModelSettingsState();
}

class _ModelSettingsState extends State<ModelSettings> {
  late final controller = ModelSettingsController(
    widget.store,
    inspectInventory: widget.inspectInventory,
  );
  late final initial = controller.initial;
  late final url = TextEditingController(text: initial.baseUrl);
  late final model = TextEditingController(text: initial.model);
  final presetName = TextEditingController();
  late int chatOutputTokens = initial.chatOutputTokens;
  LocalModelConfig get config => LocalModelConfig(
    baseUrl: url.text.trim(),
    model: model.text.trim(),
    chatOutputTokens: chatOutputTokens,
  );
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    url.addListener(controller.clearInventory);
    model.addListener(controller.clearInventory);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    url.dispose();
    model.dispose();
    presetName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Local model · Qwen 9B'),
    content: SizedBox(
      width: 540,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Start your existing model in a local server with a compatible /v1/chat/completions API. This app connects to it; it does not install a runtime or download weights.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: url,
            enabled: !controller.busy && !controller.settingsLoadFailed,
            decoration: const InputDecoration(labelText: 'Local API base URL'),
          ),
          TextField(
            controller: model,
            enabled: !controller.busy && !controller.settingsLoadFailed,
            decoration: const InputDecoration(
              labelText: 'Exact server model ID',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            key: ValueKey(chatOutputTokens),
            initialValue: chatOutputTokens,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Chat output tokens'),
            items: LocalModelConfig.chatTokenOptions
                .map(
                  (value) =>
                      DropdownMenuItem(value: value, child: Text('$value')),
                )
                .toList(),
            onChanged: controller.busy || controller.settingsLoadFailed
                ? null
                : (value) {
                    if (value != null) {
                      controller.clearInventory();
                      setState(() => chatOutputTokens = value);
                    }
                  },
          ),
          const Text(
            'Applies to the next chat request after Save. This is a requested output ceiling; the server may impose a lower limit. Connection tests, source edits and repairs use separate fixed limits.',
          ),
          const SizedBox(height: 16),
          const Text(
            'On Android Emulator, use 10.0.2.2 instead of 127.0.0.1 to reach this Mac. Physical phones need a separate secured connection; it is not configured here.',
          ),
          const SizedBox(height: 16),
          const Text('Saved connection presets'),
          DropdownButton<String>(
            value: controller.selectedPreset,
            hint: const Text('Restore a preset into draft'),
            isExpanded: true,
            items: controller.presets
                .map(
                  (p) => DropdownMenuItem(
                    value: p.name,
                    child: Text(p.name, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged:
                controller.busy ||
                    controller.presetsLoadFailed ||
                    controller.settingsLoadFailed
                ? null
                : (name) {
                    if (name == null) return;
                    final restored = controller.selectPreset(name);
                    if (restored == null) return;
                    setState(() {
                      url.text = restored.baseUrl;
                      model.text = restored.model;
                      chatOutputTokens = restored.chatOutputTokens;
                      presetName.text = name;
                    });
                  },
          ),
          TextField(
            controller: presetName,
            enabled:
                !controller.busy &&
                !controller.presetsLoadFailed &&
                !controller.settingsLoadFailed,
            maxLength: 64,
            decoration: const InputDecoration(labelText: 'New preset name'),
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed:
                    controller.busy ||
                        controller.presetsLoadFailed ||
                        controller.settingsLoadFailed
                    ? null
                    : () => controller.savePreset(presetName.text, config),
                child: const Text('Save new preset'),
              ),
              OutlinedButton(
                onPressed:
                    controller.busy ||
                        controller.presetsLoadFailed ||
                        controller.settingsLoadFailed ||
                        controller.selectedPreset == null
                    ? null
                    : () => controller.savePreset(
                        controller.selectedPreset!,
                        config,
                        replace: true,
                      ),
                child: const Text('Replace selected'),
              ),
              TextButton(
                onPressed:
                    controller.busy ||
                        controller.presetsLoadFailed ||
                        controller.settingsLoadFailed ||
                        controller.selectedPreset == null
                    ? null
                    : controller.removePreset,
                child: const Text('Remove selected'),
              ),
            ],
          ),
          Text(controller.presetStatus),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: controller.busy || controller.settingsLoadFailed
                ? null
                : () => controller.inspectInventory(config),
            child: const Text('Inspect draft model ID'),
          ),
          if (controller.inventoryStatus != null)
            Text(controller.inventoryStatus!),
          const SizedBox(height: 16),
          const Text(ModelSettingsController.requestLimits),
          const SizedBox(height: 16),
          SelectableText(controller.status),
          if (controller.busy) const LinearProgressIndicator(),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      if (controller.testing)
        OutlinedButton(
          onPressed: controller.stopTest,
          child: const Text('Stop test'),
        ),
      OutlinedButton(
        onPressed: controller.busy || controller.settingsLoadFailed
            ? null
            : () => controller.test(config),
        child: const Text('Test model'),
      ),
      FilledButton(
        onPressed: controller.busy || controller.settingsLoadFailed
            ? null
            : () => controller.save(config),
        child: const Text('Save'),
      ),
    ],
  );
}

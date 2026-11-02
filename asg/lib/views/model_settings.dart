// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../services/model_settings_store.dart';
import '../controllers/model_settings_controller.dart';

import '../models/local_model_config.dart';
import '../models/model_profile_notes.dart';
import '../models/model_format_probe.dart';
import 'model_profile_notes_fields.dart';
import 'model_test_observation_view.dart';

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
  final profileFields = List.generate(6, (_) => TextEditingController());
  ModelProfileNotes? get profileNotes {
    final context = profileFields[5].text.trim();
    final notes = ModelProfileNotes(
      revision: profileFields[0].text.trim(),
      license: profileFields[1].text.trim(),
      architecture: profileFields[2].text.trim(),
      quantization: profileFields[3].text.trim(),
      backend: profileFields[4].text.trim(),
      contextTokens: context.isEmpty ? null : int.tryParse(context) ?? -1,
    );
    return notes.isEmpty ? null : notes;
  }

  void restoreNotes(ModelProfileNotes? notes) {
    final values = [
      notes?.revision ?? '',
      notes?.license ?? '',
      notes?.architecture ?? '',
      notes?.quantization ?? '',
      notes?.backend ?? '',
      notes?.contextTokens?.toString() ?? '',
    ];
    for (var i = 0; i < profileFields.length; i++) {
      profileFields[i].text = values[i];
    }
  }

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
    lastUrl = url.text;
    lastModel = model.text;
    url.addListener(connectionTextChanged);
    model.addListener(connectionTextChanged);
  }

  late String lastUrl = url.text;
  late String lastModel = model.text;

  void connectionTextChanged() {
    if (lastUrl == url.text && lastModel == model.text) return;
    lastUrl = url.text;
    lastModel = model.text;
    controller.connectionDraftChanged();
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
    for (final field in profileFields) {
      field.dispose();
    }
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
                      controller.connectionDraftChanged();
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
                      restoreNotes(
                        controller.presets
                            .firstWhere((p) => p.name == name)
                            .profileNotes,
                      );
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
          ModelProfileNotesFields(
            fields: profileFields,
            enabled:
                !controller.busy &&
                !controller.presetsLoadFailed &&
                !controller.settingsLoadFailed,
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
                    : () => controller.savePreset(
                        presetName.text,
                        config,
                        profileNotes: profileNotes,
                      ),
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
                        profileNotes: profileNotes,
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
          const Text(
            'After a successful test, explicitly save its observation to a selected '
            'preset with the same connection draft. Replacing a preset clears its '
            'historical observation. Only the latest saved test is retained.',
          ),
          OutlinedButton(
            onPressed: controller.canSaveTestObservation(config)
                ? () => controller.saveTestObservation(config)
                : null,
            child: const Text('Save test observation to selected preset'),
          ),
          for (final preset in controller.presets)
            if (preset.name == controller.selectedPreset)
              ModelTestObservationView(preset: preset),
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
          const SizedBox(height: 8),
          const Text(ModelFormatProbe.guidance),
          const SizedBox(height: 8),
          const Text(ModelSettingsController.timingGuidance),
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
      OutlinedButton(
        onPressed: controller.busy || controller.settingsLoadFailed
            ? null
            : () => controller.test(config, jsonFormat: true),
        child: const Text('Test JSON format'),
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

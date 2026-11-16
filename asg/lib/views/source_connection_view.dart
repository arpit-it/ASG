// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/model_connection_preset.dart';
import '../controllers/source_review_controller.dart';

class SourceConnectionView extends StatelessWidget {
  const SourceConnectionView({super.key, required this.controller});
  final SourceReviewController controller;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const ValueKey('sourceConnectionSettings'),
    title: const Text('Source/repair request connection'),
    subtitle: Text(
      controller.connectionPreset == null
          ? 'Global model settings'
          : 'Selected: ${controller.connectionPreset!.name} · ${controller.connectionPreset!.config.model}',
    ),
    children: [
      InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Source/repair connection',
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<Object>(
            key: const ValueKey('sourceConnection'),
            value: controller.connectionPreset == null ? -1 : -2,
            isExpanded: true,
            items: [
              const DropdownMenuItem(
                value: -1,
                child: Text('Global model settings'),
              ),
              if (controller.connectionPreset != null)
                DropdownMenuItem(
                  value: -2,
                  child: Text(
                    'Selected: ${controller.connectionPreset!.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              for (final preset in controller.presets)
                DropdownMenuItem(
                  value: preset,
                  child: Text(
                    preset.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: controller.canChooseConnection
                ? (selection) {
                    if (selection == -1) {
                      controller.choosePreset(null);
                    } else if (selection is ModelConnectionPreset) {
                      controller.choosePreset(selection);
                    }
                  }
                : null,
          ),
        ),
      ),
      const Text(
        'Applies to source proposals and repairs in this review session only; reopening uses global settings. Automatic repairs keep one connection for the entire session. Requests use a fixed 4096-token output ceiling, independent of the preset chat limit. Selection does not load or test weights or change global, chat or prototype connections.',
      ),
      TextButton(
        onPressed: controller.canChooseConnection
            ? controller.refreshPresets
            : null,
        child: const Text('Refresh source/repair connection presets'),
      ),
      if (controller.presetError != null) Text(controller.presetError!),
    ],
  );
}

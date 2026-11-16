// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/app_workspace_controller.dart';
import '../models/model_connection_preset.dart';

class PrototypeConnectionView extends StatelessWidget {
  const PrototypeConnectionView({super.key, required this.controller});
  final AppWorkspaceController controller;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const ValueKey('prototypeConnectionSettings'),
    title: const Text('Prototype request connection'),
    subtitle: Text(
      controller.connectionPreset == null
          ? 'Global model settings'
          : 'Selected: ${controller.connectionPreset!.name} · ${controller.connectionPreset!.config.model}',
    ),
    children: [
      InputDecorator(
        decoration: const InputDecoration(labelText: 'Prototype connection'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<Object>(
            key: const ValueKey('prototypeConnection'),
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
        'Applies to prototype instructions in this workspace session only; reopening uses global settings. Model requests use a fixed 2048-token output ceiling, independent of the preset chat limit. Built-in actions use no model. Selection does not load or test weights or change global, advisory-chat, source or repair connections.',
      ),
      TextButton(
        onPressed: controller.canChooseConnection
            ? controller.refreshPresets
            : null,
        child: const Text('Refresh prototype connection presets'),
      ),
      if (controller.presetError != null) Text(controller.presetError!),
    ],
  );
}

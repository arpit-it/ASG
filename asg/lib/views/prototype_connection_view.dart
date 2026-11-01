// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/app_workspace_controller.dart';

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
          child: DropdownButton<int>(
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
              for (var i = 0; i < controller.presets.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    controller.presets[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: controller.canChooseConnection
                ? (index) {
                    if (index == null || index == -2) return;
                    controller.choosePreset(
                      index == -1 ? null : controller.presets[index],
                    );
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

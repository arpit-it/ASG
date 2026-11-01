// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/runtime_setup_controller.dart';

/// Session-only opt-in to checking installed experimental CPU dependencies.
class CpuEnvironmentPreparationPanel extends StatefulWidget {
  const CpuEnvironmentPreparationPanel({
    super.key,
    required this.controller,
    required this.python,
  });

  final RuntimeSetupController controller;
  final TextEditingController python;

  @override
  State<CpuEnvironmentPreparationPanel> createState() =>
      _CpuEnvironmentPreparationPanelState();
}

class _CpuEnvironmentPreparationPanelState
    extends State<CpuEnvironmentPreparationPanel> {
  bool consent = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Card(
      child: ExpansionTile(
        title: const Text('Experimental CPU dependency check'),
        childrenPadding: const EdgeInsets.all(24),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Check installed Torch, Transformers and safetensors using the Python executable above. '
            'This prepares the local helper without installing packages, downloading models or loading weights. '
            'Success checks dependencies only: checkpoint compatibility, memory adequacy and CPU inference remain unverified. '
            'The active runtime and saved connection are unchanged.',
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow this experimental CPU dependency check'),
            subtitle: const Text(
              'Session only. Does not enable CPU inference.',
            ),
            value: consent,
            onChanged: controller.busy
                ? null
                : (value) => setState(() => consent = value ?? false),
          ),
          OutlinedButton.icon(
            onPressed:
                controller.busy || !consent || widget.python.text.trim().isEmpty
                ? null
                : () => controller.prepareCpuEnvironment(
                    widget.python.text,
                    experimentalCpu: consent,
                  ),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Check CPU dependencies'),
          ),
          if (controller.busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/runtime_setup_controller.dart';
import '../models/cpu_checkpoint_inspection.dart';

/// Separate no-load experiment; never selects or enables a managed CPU backend.
class CpuCheckpointInspectionPanel extends StatefulWidget {
  const CpuCheckpointInspectionPanel({
    super.key,
    required this.controller,
    required this.python,
  });

  final RuntimeSetupController controller;
  final TextEditingController python;

  @override
  State<CpuCheckpointInspectionPanel> createState() =>
      _CpuCheckpointInspectionPanelState();
}

class _CpuCheckpointInspectionPanelState
    extends State<CpuCheckpointInspectionPanel> {
  final checkpoint = TextEditingController();
  final ceiling = TextEditingController();
  bool consent = false;

  int? get maxBytes => int.tryParse(ceiling.text.trim());
  bool get validCeiling =>
      ceiling.text.trim().isEmpty ||
      (RegExp(r'^[0-9]+$').hasMatch(ceiling.text.trim()) &&
          maxBytes != null &&
          maxBytes! > 0 &&
          maxBytes! <= 9007199254740991);

  @override
  void initState() {
    super.initState();
    checkpoint.addListener(inputsChanged);
    ceiling.addListener(inputsChanged);
  }

  void inputsChanged() {
    widget.controller.invalidateCapabilities();
    setState(() {});
  }

  @override
  void dispose() {
    checkpoint.dispose();
    ceiling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final report = controller.cpuCheckpointInspection;
    return Card(
      child: ExpansionTile(
        title: const Text('Experimental CPU checkpoint inspection'),
        childrenPadding: const EdgeInsets.all(24),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Inspect an existing local Torch checkpoint using the Python executable above. '
            'This checks structure and disk bytes without loading weights, installing packages or starting a runtime. '
            'CPU inference remains experimental and unverified; MLX quantized weights cannot be reused.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: checkpoint,
            enabled: !controller.busy,
            decoration: const InputDecoration(
              labelText: 'Experimental CPU checkpoint folder',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: ceiling,
            enabled: !controller.busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Optional maximum weight bytes on disk',
              helperText:
                  'Blank means no disk-byte ceiling. This is not a RAM limit.',
              helperMaxLines: 3,
              errorText: validCeiling ? null : 'Enter whole bytes from 1 to 9007199254740991, or leave blank.',
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow this experimental no-load CPU inspection'),
            subtitle: const Text(
              'Session only. Does not enable CPU inference.',
            ),
            value: consent,
            onChanged: controller.busy
                ? null
                : (value) {
                    controller.invalidateCapabilities();
                    setState(() => consent = value ?? false);
                  },
          ),
          OutlinedButton.icon(
            onPressed:
                controller.busy ||
                    !consent ||
                    widget.python.text.trim().isEmpty ||
                    checkpoint.text.trim().isEmpty ||
                    !validCeiling
                ? null
                : () => controller.inspectCpuCheckpoint(
                    widget.python.text,
                    checkpoint.text,
                    experimentalCpu: consent,
                    maxWeightBytes: maxBytes,
                  ),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Inspect CPU checkpoint'),
          ),
          if (controller.busy) const LinearProgressIndicator(),
          if (consent && report != null) ...[
            const SizedBox(height: 12),
            Text('Observed weight bytes on disk: ${report.weightBytes}'),
            Text('Distinct weight files: ${report.weightFileCount}'),
            const Text('CPU inference readiness: unverified'),
            const Text(CpuCheckpointInspection.scope),
          ],
        ],
      ),
    );
  }
}

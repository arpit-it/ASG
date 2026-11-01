// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/runtime_setup_controller.dart';
import '../models/runtime_setup.dart';

/// Session-only consent to a controlled CPU launch, separate from saved setup.
class CpuRuntimeLaunchPanel extends StatefulWidget {
  const CpuRuntimeLaunchPanel({
    super.key,
    required this.controller,
    required this.python,
  });
  final RuntimeSetupController controller;
  final TextEditingController python;

  @override
  State<CpuRuntimeLaunchPanel> createState() => _CpuRuntimeLaunchPanelState();
}

class _CpuRuntimeLaunchPanelState extends State<CpuRuntimeLaunchPanel>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final checkpoint = TextEditingController();
  final model = TextEditingController();
  final ceiling = TextEditingController();
  final deadline = TextEditingController(text: '180');
  final threads = TextEditingController(text: '2');
  bool consent = false;

  int? get threadCount => int.tryParse(threads.text.trim());
  bool get validThreads =>
      RegExp(r'^[0-9]+$').hasMatch(threads.text.trim()) &&
      threadCount != null &&
      threadCount! >= 1 &&
      threadCount! <= 32;

  int? get loadSeconds => int.tryParse(deadline.text.trim());
  bool get validDeadline =>
      RegExp(r'^[0-9]+$').hasMatch(deadline.text.trim()) &&
      loadSeconds != null &&
      loadSeconds! >= 1 &&
      loadSeconds! <= 3600;

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
    checkpoint.addListener(refresh);
    model.addListener(refresh);
    ceiling.addListener(refresh);
    deadline.addListener(refresh);
    threads.addListener(refresh);
  }

  void refresh() => setState(() {});

  @override
  void dispose() {
    checkpoint.dispose();
    model.dispose();
    ceiling.dispose();
    deadline.dispose();
    threads.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = widget.controller;
    return Card(
      child: ExpansionTile(
        title: const Text('Experimental CPU launch'),
        childrenPadding: const EdgeInsets.all(24),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Start an experimental local Torch CPU process using the Python executable above and an existing compatible checkpoint. This can load weights and consume substantial RAM. MLX quantized weights cannot be reused. No packages or models are downloaded. Saved setup and connection remain unchanged.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: checkpoint,
            enabled: !c.busy,
            decoration: const InputDecoration(
              labelText: 'CPU launch checkpoint folder',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: model,
            enabled: !c.busy,
            decoration: const InputDecoration(
              labelText: 'CPU launch model ID',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Limits: configurable Torch threads and server load deadline. These are not a RAM quota or proof that the model fits.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ceiling,
            enabled: !c.busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'CPU launch maximum weight bytes on disk (optional)',
              helperText:
                  'Blank means no disk-byte ceiling. This is not a RAM limit.',
              helperMaxLines: 3,
              errorText: validCeiling ? null : 'Enter whole bytes from 1 to 9007199254740991, or leave blank.',
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: deadline,
            enabled: !c.busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'CPU load deadline (seconds)',
              helperText: 'Stops the dedicated runtime if weight loading exceeds this deadline. Default: 180 seconds.',
              helperMaxLines: 4,
              errorText: validDeadline
                  ? null
                  : 'Enter whole seconds from 1 to 3600.',
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: threads,
            enabled: !c.busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'CPU launch threads',
              helperText: 'Torch intra-operation threads, from 1 to 32. Default: 2. This does not cap total CPU or RAM use.',
              helperMaxLines: 4,
              errorText: validThreads
                  ? null
                  : 'Enter a whole thread count from 1 to 32.',
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Allow experimental CPU weight loading and launch',
            ),
            subtitle: const Text(
              'Session only. CPU inference support remains unverified.',
            ),
            value: consent,
            onChanged: c.busy
                ? null
                : (v) => setState(() => consent = v ?? false),
          ),
          OutlinedButton.icon(
            onPressed:
                c.busy ||
                    c.health.ready ||
                    c.host.ownsProcess ||
                    !consent ||
                    !validCeiling ||
                    !validDeadline ||
                    !validThreads ||
                    widget.python.text.trim().isEmpty ||
                    checkpoint.text.trim().isEmpty ||
                    model.text.trim().isEmpty
                ? null
                : () => c.startCpuRuntime(
                    RuntimeSetup(
                      python: widget.python.text,
                      modelPath: checkpoint.text,
                    ),
                    model.text,
                    experimentalCpu: consent,
                    threads: threadCount!,
                    maxWeightBytes: maxBytes,
                    loadTimeout: Duration(seconds: loadSeconds!),
                  ),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Launch experimental CPU'),
          ),
          if (c.cpuLaunching)
            OutlinedButton.icon(
              onPressed: c.stop,
              icon: const Icon(Icons.stop),
              label: const Text('Stop CPU launch'),
            ),
          if (c.busy) const LinearProgressIndicator(),
          const Text(
            'Launch is not readiness confirmation. Refresh status separately before connecting. Memory adequacy and real-host CPU inference remain unverified.',
          ),
        ],
      ),
    );
  }
}

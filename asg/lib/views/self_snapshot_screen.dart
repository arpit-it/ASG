// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/self_snapshot_controller.dart';
import '../services/folder_picker.dart';

class SelfSnapshotScreen extends StatefulWidget {
  const SelfSnapshotScreen({
    super.key,
    required this.controller,
    required this.picker,
  });

  final SelfSnapshotController controller;
  final FolderPicker picker;

  @override
  State<SelfSnapshotScreen> createState() => _SelfSnapshotScreenState();
}

class _SelfSnapshotScreenState extends State<SelfSnapshotScreen> {
  final commit = TextEditingController();
  final python = TextEditingController();
  String source = '';
  String destination = '';
  bool picking = false;

  Future<void> pick({required bool sourceFolder}) async {
    setState(() => picking = true);
    try {
      final selected = await widget.picker.pick();
      if (selected == null || !mounted) return;
      setState(() {
        if (sourceFolder) {
          source = selected;
        } else {
          destination = selected;
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the folder picker.')),
        );
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  @override
  void dispose() {
    commit.dispose();
    python.dispose();
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Prepare ASG source snapshot')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final enabled = !controller.busy && !picking;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Use a trusted local ASG checkout and Python executable. '
                'Preparation copies committed source files into a separate folder.',
              ),
              TextButton(
                onPressed: enabled ? () => pick(sourceFolder: true) : null,
                child: const Text('Choose trusted checkout'),
              ),
              if (source.isNotEmpty) SelectableText(source),
              TextButton(
                onPressed: enabled ? () => pick(sourceFolder: false) : null,
                child: const Text('Choose snapshot destination'),
              ),
              if (destination.isNotEmpty) SelectableText(destination),
              TextField(
                controller: commit,
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: 'Reviewed commit ID',
                ),
              ),
              TextField(
                controller: python,
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: 'Python executable path',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: enabled
                    ? () => controller.prepare(
                        source: source,
                        destination: destination,
                        commit: commit.text.trim(),
                        python: python.text.trim(),
                      )
                    : null,
                child: const Text('Prepare source snapshot'),
              ),
              if (controller.busy)
                OutlinedButton(
                  onPressed: controller.stopping ? null : controller.stop,
                  child: Text(controller.stopping ? 'Stopping…' : 'Stop'),
                ),
              if (controller.status case final status?) SelectableText(status),
            ],
          );
        },
      ),
    );
  }
}

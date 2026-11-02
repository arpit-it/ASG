// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/project_runner.dart';

/// Read-only description shared by creation and the starter workflow.
class RunnerCapabilities extends StatelessWidget {
  const RunnerCapabilities({super.key, required this.descriptor});
  final ProjectRunnerDescriptor descriptor;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('Runner capabilities'),
    subtitle: Text('${descriptor.id} v${descriptor.version}'),
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'Adapter: ${descriptor.adapterId}. Fixed starter only. Availability '
          'describes an action, not a passed check or verified browser. No '
          'external compiler or package manager is used. A browser is needed '
          'to view the preview; browser installation and version are not '
          'verified here. Full HTML project registration and approved-task '
          'integration remain planned.',
        ),
      ),
      for (final operation in RunnerOperation.values)
        ListTile(
          title: Text(switch (operation) {
            RunnerOperation.checkSources => 'Source identity',
            RunnerOperation.resolveDependencies => 'Resolve dependencies',
            RunnerOperation.compile => 'Compile',
            RunnerOperation.test => 'Project tests',
            RunnerOperation.run => 'Preview host',
            RunnerOperation.open => 'Browser launch',
            RunnerOperation.stop => 'Preview cleanup',
          }),
          subtitle: Text(
            '${switch (descriptor.capability(operation).availability) {
              RunnerAvailability.available => 'Available',
              RunnerAvailability.unavailableHost => 'Unavailable on this host',
              RunnerAvailability.notApplicable => 'Not applicable',
              RunnerAvailability.notImplemented => 'Not implemented',
            }}: ${descriptor.capability(operation).reason}',
          ),
        ),
    ],
  );
}

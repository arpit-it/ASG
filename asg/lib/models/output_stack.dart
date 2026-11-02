// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Creation choices describe delivered paths; they never grant execution.
enum OutputStackStatus { implemented, planned }

class OutputStack {
  const OutputStack(this.type, this.label, this.status, this.detail);
  final String type, label, detail;
  final OutputStackStatus status;

  bool get canCreate => status == OutputStackStatus.implemented;

  static const catalog = [
    OutputStack(
      'Flutter',
      'Flutter / Dart',
      OutputStackStatus.implemented,
      'In-app prototype and fixed Flutter web starter. Independent source '
          'generation requires the macOS host, Flutter SDK, Python and an '
          'approved plan. Selected device targets are project intent, not '
          'verified native output. This choice does not verify toolchain '
          'versions or readiness; inspect paths in Build before generation.',
    ),
    OutputStack(
      'HTML',
      'HTML / CSS / JavaScript',
      OutputStackStatus.planned,
      'Fixed HTML starter export, saved-starter library and exact-starter preview '
          'are available separately on macOS. Full HTML project creation and '
          'approved-task integration remain planned. Creation is unavailable; '
          'this choice will not create a Flutter project.',
    ),
    OutputStack(
      'Python',
      'Python',
      OutputStackStatus.planned,
      'Planned: Python CLI and service projects. No Python project runner or '
          'verified toolchain/version is available yet. Creation is unavailable; '
          'this choice will not create a Flutter project.',
    ),
  ];

  static OutputStack? forType(String type) {
    for (final stack in catalog) {
      if (stack.type == type) return stack;
    }
    return null;
  }
}

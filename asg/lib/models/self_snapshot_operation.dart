// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

enum SelfSnapshotOperation {
  resolve('Offline dependency resolution'),
  analyze('Analysis'),
  build('Offline web build');

  const SelfSnapshotOperation(this.label);
  final String label;
}

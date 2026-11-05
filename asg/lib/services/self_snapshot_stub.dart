// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

bool get supportsSelfSnapshot => false;

Future<String> prepareSelfSnapshot({
  required String source,
  required String destination,
  required String commit,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
}) async => throw UnsupportedError('Source snapshots require macOS.');

Future<List<String>> inspectIncompleteSnapshots(String destination) async =>
    throw UnsupportedError('Source snapshots require macOS.');

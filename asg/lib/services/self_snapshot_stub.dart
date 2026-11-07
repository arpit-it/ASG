// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/candidate_file_review.dart';
import '../models/candidate_comparison.dart';
import '../models/generation_command_result.dart';
import '../models/self_snapshot_operation.dart';

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

Future<GenerationCommandResult> checkSelfSnapshot({
  required String snapshot,
  required String sdk,
  required String python,
  required SelfSnapshotOperation operation,
  required Future<void> stop,
  required bool Function() stopped,
}) async => throw UnsupportedError('Snapshot checks require macOS.');

Future<String> fingerprintSelfSnapshot({
  required String snapshot,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
}) async => throw UnsupportedError('Candidate review requires macOS.');

Future<CandidateComparison> compareSelfSnapshot({
  required String snapshot,
  required String source,
  required String commit,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
}) async => throw UnsupportedError('Candidate comparison requires macOS.');

Future<CandidateFileReview> reviewSelfSnapshotFile({
  required String snapshot,
  required String source,
  required String commit,
  required String digest,
  required String file,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
}) async => throw UnsupportedError('Candidate review requires macOS.');

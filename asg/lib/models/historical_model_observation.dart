// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// A retained workload observation, never a current-runtime capability.
class HistoricalModelObservation {
  const HistoricalModelObservation({
    required this.recordedAt,
    required this.sourceRevision,
    required this.runs,
    required this.disconnectSeconds,
    required this.weightBytes,
  });
  final DateTime recordedAt;
  final String sourceRevision;
  final List<HistoricalModelRun> runs;
  final double disconnectSeconds;
  final int weightBytes;
}

class HistoricalModelRun {
  const HistoricalModelRun({
    required this.label,
    required this.promptTokens,
    required this.completionTokens,
    required this.tokensPerSecond,
    required this.processPeakGb,
  });
  final String label;
  final int promptTokens, completionTokens;
  final double tokensPerSecond, processPeakGb;
}

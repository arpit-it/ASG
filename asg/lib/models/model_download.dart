// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

enum DownloadPhase {
  idle,
  starting,
  downloading,
  pausing,
  paused,
  stopping,
  stopped,
  failed,
  complete,
}

class ModelDownloadProgress {
  const ModelDownloadProgress({
    this.phase = DownloadPhase.idle,
    this.bytes = 0,
    this.total,
    this.bytesPerSecond = 0,
    this.problem,
  });
  final DownloadPhase phase;
  final int bytes;
  final int? total;
  final double bytesPerSecond;
  final String? problem;
  bool get active => [
    DownloadPhase.starting,
    DownloadPhase.downloading,
    DownloadPhase.pausing,
    DownloadPhase.stopping,
  ].contains(phase);
  double? get fraction =>
      total == null || total == 0 ? null : (bytes / total!).clamp(0, 1);
  ModelDownloadProgress withPhase(DownloadPhase value, {String? problem}) =>
      ModelDownloadProgress(
        phase: value,
        bytes: bytes,
        total: total,
        problem: problem,
      );

  /// Only a small numeric protocol reaches the UI. Never forward child text.
  static ModelDownloadProgress? parse(String line) {
    if (line.length > 1024) return null;
    try {
      final data = jsonDecode(line);
      if (data is! Map || data['v'] != 1 || data['event'] != 'progress') {
        return null;
      }
      final bytes = data['bytes'], total = data['total'], speed = data['speed'];
      if (bytes is! int ||
          bytes < 0 ||
          bytes > 1 << 53 ||
          (total != null &&
              (total is! int || total < bytes || total > 1 << 53)) ||
          speed is! num ||
          !speed.isFinite ||
          speed < 0 ||
          speed > 1e13) {
        return null;
      }
      return ModelDownloadProgress(
        phase: DownloadPhase.downloading,
        bytes: bytes,
        total: total as int?,
        bytesPerSecond: speed.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }
}

class DownloadInterrupted implements Exception {
  const DownloadInterrupted();
}

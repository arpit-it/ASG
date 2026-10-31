// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/model_download.dart';

class ModelDownloadPanel extends StatelessWidget {
  const ModelDownloadPanel({
    super.key,
    required this.progress,
    required this.busy,
    required this.onPause,
    required this.onResume,
    required this.onStop,
  });
  final ModelDownloadProgress progress;
  final bool busy;
  final VoidCallback onPause, onResume, onStop;
  static String size(num bytes) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var value = bytes.toDouble(), unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final active = progress.active;
    final canInterrupt = [
      DownloadPhase.starting,
      DownloadPhase.downloading,
    ].contains(progress.phase);
    final fraction = progress.fraction;
    final status = switch (progress.phase) {
      DownloadPhase.idle =>
        'Ready to start a new download or resume an ASG partial download.',
      DownloadPhase.starting => 'Connecting and checking artifact sizes…',
      DownloadPhase.downloading => 'Downloading model artifacts',
      DownloadPhase.pausing => 'Pausing download…',
      DownloadPhase.paused => 'Download paused',
      DownloadPhase.stopping => 'Stopping download…',
      DownloadPhase.stopped => 'Download stopped',
      DownloadPhase.failed => 'Download failed — partial files retained',
      DownloadPhase.complete =>
        'Transfer complete — checkpoint validation follows',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status, key: const ValueKey('download-status')),
          if (progress.phase != DownloadPhase.idle) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: fraction,
              semanticsLabel: 'Model download progress',
            ),
            const SizedBox(height: 8),
            Text(
              '${size(progress.bytes)} / ${progress.total == null ? 'unknown size' : size(progress.total!)}${fraction == null ? '' : ' · ${(fraction * 100).toStringAsFixed(1)}%'}',
            ),
            Text(
              active && progress.bytesPerSecond > 0
                  ? '${size(progress.bytesPerSecond)}/s'
                  : active
                  ? 'Speed: calculating…'
                  : 'Speed: —',
            ),
          ],
          if (progress.problem != null) Text(progress.problem!),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: canInterrupt ? onPause : null,
                icon: const Icon(Icons.pause),
                label: const Text('Pause download'),
              ),
              OutlinedButton.icon(
                onPressed: !busy && !active ? onResume : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume download'),
              ),
              OutlinedButton.icon(
                onPressed: canInterrupt ? onStop : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop download'),
              ),
            ],
          ),
          const Text(
            'Pause and Stop end this transfer and retain partial files. Resume requires the same repository, pinned revision and destination. Leaving setup stops an active transfer. Inference is unchanged.',
          ),
        ],
      ),
    );
  }
}

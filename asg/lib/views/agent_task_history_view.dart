// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/agent_task_history.dart';
import '../models/build_task.dart';

/// Renders saved observations only. Expanding this view starts no actions.
class AgentTaskHistoryView extends StatelessWidget {
  const AgentTaskHistoryView({super.key, required this.history});
  final AgentTaskHistory? history;

  static String _operation(BuildOperation operation) => switch (operation) {
    BuildOperation.resolve => 'Resolve dependencies',
    BuildOperation.analyze => 'Analyze source',
    BuildOperation.test => 'Run tests',
    BuildOperation.build => 'Build Flutter web',
  };

  String _label(AgentTaskObservation observation) => switch (observation.kind) {
    AgentTaskObservationKind.admitted => 'Verification admitted',
    AgentTaskObservationKind.pending =>
      '${_operation(observation.operation!)} — intent recorded',
    AgentTaskObservationKind.result =>
      '${_operation(observation.operation!)} — recorded exit ${observation.exitCode}${observation.cancelled! ? '; reported cancelled' : ''}',
    AgentTaskObservationKind.interrupted =>
      '${_operation(observation.operation!)} — interrupted; outcome unknown',
    AgentTaskObservationKind.finished => 'Verification attempt finished',
  };

  Widget _row(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Align(alignment: Alignment.centerLeft, child: Text(text)),
  );

  @override
  Widget build(BuildContext context) {
    final saved = history;
    if (saved == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Task observations are unavailable for this saved run.'),
      );
    }
    return ExpansionTile(
      key: ValueKey(
        'task-history-${saved.session.sessionId}-${saved.reference.dispatchId}',
      ),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
      title: Text('Task observations (${saved.observations.length})'),
      subtitle: const Text('Saved history; opening starts no work.'),
      children: [
        const Text(
          'These observations do not establish live process status or task completion.',
        ),
        for (final observation in saved.observations) ...[
          if (saved.withdrawalSequence == observation.sequence)
            _row('Session withdrawal recorded'),
          _row('${observation.sequence + 1}. ${_label(observation)}'),
        ],
        if (saved.withdrawalSequence == saved.observations.length)
          _row('Session withdrawal recorded'),
        if (saved.pendingOperation case final operation?)
          _row(
            '${_operation(operation)} has no saved result. Its outcome is unknown.',
          ),
      ],
    );
  }
}

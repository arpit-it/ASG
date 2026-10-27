import 'package:flutter/material.dart';

import '../controllers/requirement_check_report_controller.dart';
import '../models/requirement_check_report.dart';

class RequirementCheckReportScreen extends StatefulWidget {
  const RequirementCheckReportScreen({super.key, required this.controller});
  final RequirementCheckReportController controller;
  @override
  State<RequirementCheckReportScreen> createState() =>
      _RequirementCheckReportScreenState();
}

class _RequirementCheckReportScreenState
    extends State<RequirementCheckReportScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.load();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final report = widget.controller.report;
      return Scaffold(
        appBar: AppBar(title: const Text('Requirement check report')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(RequirementCheckReport.limits),
            TextButton(
              onPressed: widget.controller.load,
              child: const Text('Reload saved evidence'),
            ),
            if (widget.controller.error != null)
              SelectableText(widget.controller.error!),
            if (report != null) ...[
              Text('Requirements revision ${report.requirementsRevision}'),
              if (report.results.isEmpty)
                const Text('No structured requirements recorded.'),
              for (final result in report.results)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${result.requirement.id}: ${result.requirement.title}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(result.label),
                        Text(result.reason),
                        Text(
                          'Tasks: ${result.taskIds.isEmpty ? 'none' : result.taskIds.join(', ')}',
                        ),
                        Text(
                          'Operations: ${result.operationIds.isEmpty ? 'none' : result.operationIds.join(', ')}',
                        ),
                      ],
                    ),
                  ),
                ),
              ExpansionTile(
                title: const Text('Exact saved revision and results'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(report.evidenceJson),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    },
  );
}

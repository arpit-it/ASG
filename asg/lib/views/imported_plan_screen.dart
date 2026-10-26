import 'package:flutter/material.dart';

import '../controllers/imported_plan_controller.dart';

class ImportedPlanScreen extends StatefulWidget {
  const ImportedPlanScreen({super.key, required this.controller});
  final ImportedPlanController controller;
  @override
  State<ImportedPlanScreen> createState() => _ImportedPlanScreenState();
}

class _ImportedPlanScreenState extends State<ImportedPlanScreen> {
  final text = TextEditingController();
  ImportedPlanController get controller => widget.controller;
  bool hydrated = false;
  bool edited = false;
  Future<void> load() async {
    await controller.load();
    if (mounted && controller.error == null && !hydrated && !edited) {
      hydrated = true;
      text.text = controller.plan?.text ?? '';
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    text.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => PopScope(
      canPop: !controller.busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Imported project plan')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Write a plan against the saved requirements and inspected folder metadata. Approval records review consent only. Source editing and execution are unavailable; no project files are changed.',
            ),
            SelectableText('Folder: ${controller.root}'),
            if (controller.busy) const LinearProgressIndicator(),
            if (controller.error != null) ...[
              SelectableText(controller.error!),
              TextButton(
                onPressed: controller.busy ? null : load,
                child: const Text('Reload plan'),
              ),
            ],
            TextField(
              controller: text,
              onChanged: (_) => edited = true,
              enabled: !controller.busy,
              maxLength: 12000,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'Plan draft (user authored)',
              ),
            ),
            FilledButton(
              onPressed: controller.busy
                  ? null
                  : () => controller.saveDraft(text.text),
              child: const Text('Save draft'),
            ),
            if (controller.plan != null) ...[
              Text(
                controller.approved
                    ? 'Approved for current planning context'
                    : controller.current
                    ? 'Saved draft · not approved'
                    : 'Outdated or unavailable context · approval inactive',
              ),
              SelectableText('Saved plan: ${controller.plan!.text}'),
              Text('Recorded: ${controller.plan!.recordedAt.toLocal()}'),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed:
                        controller.busy ||
                            !controller.current ||
                            controller.approved
                        ? null
                        : () => controller.decide(true),
                    child: const Text('Approve saved plan'),
                  ),
                  TextButton(
                    onPressed:
                        controller.busy ||
                            !controller.current ||
                            !controller.plan!.approved
                        ? null
                        : () => controller.decide(false),
                    child: const Text('Withdraw approval'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

import 'package:flutter/material.dart';

import '../services/model_settings_store.dart';
import '../controllers/model_settings_controller.dart';

import '../models/local_model_config.dart';

class ModelSettings extends StatefulWidget {
  const ModelSettings({super.key, required this.store});
  final ModelSettingsStore store;
  @override
  State<ModelSettings> createState() => _ModelSettingsState();
}

class _ModelSettingsState extends State<ModelSettings> {
  late final controller = ModelSettingsController(widget.store);
  late final initial = controller.initial;
  late final url = TextEditingController(text: initial.baseUrl);
  late final model = TextEditingController(text: initial.model);
  LocalModelConfig get config =>
      LocalModelConfig(baseUrl: url.text.trim(), model: model.text.trim());
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    url.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Local model · Qwen 9B'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Start your existing model in a local server with a compatible /v1/chat/completions API. This app connects to it; it does not install a runtime or download weights.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: url,
              enabled: !controller.busy,
              decoration: const InputDecoration(
                labelText: 'Local API base URL',
              ),
            ),
            TextField(
              controller: model,
              enabled: !controller.busy,
              decoration: const InputDecoration(
                labelText: 'Exact server model ID',
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'On Android Emulator, use 10.0.2.2 instead of 127.0.0.1 to reach this Mac. Physical phones need a separate secured connection; it is not configured here.',
            ),
            const SizedBox(height: 16),
            const Text(ModelSettingsController.requestLimits),
            const SizedBox(height: 16),
            SelectableText(controller.status),
            if (controller.busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      if (controller.testing)
        OutlinedButton(
          onPressed: controller.stopTest,
          child: const Text('Stop test'),
        ),
      OutlinedButton(
        onPressed: controller.busy ? null : () => controller.test(config),
        child: const Text('Test model'),
      ),
      FilledButton(
        onPressed: controller.busy ? null : () => controller.save(config),
        child: const Text('Save'),
      ),
    ],
  );
}

import 'package:flutter/material.dart';

import '../models/project.dart';
import '../models/generation_event.dart';
import '../controllers/chat_controller.dart';
import 'generation_status_view.dart';

class ModelChat extends StatefulWidget {
  const ModelChat({super.key, required this.project});
  final StudioProject project;
  @override
  State<ModelChat> createState() => _ModelChatState();
}

class _ModelChatState extends State<ModelChat> {
  final input = TextEditingController();
  late final controller = ChatController(widget.project);
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    controller.load();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> send() async {
    final accepted = await controller.send(input.text);
    if (mounted && accepted) input.clear();
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Discuss · ${widget.project.name}')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Local Qwen discussion · Messages are saved on this device. No file changes or commands are executed.',
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (controller.messages.isEmpty)
                const Text(
                  'Describe your idea or ask Qwen to clarify the requirements.',
                ),
              ...controller.messages.map(
                (m) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.role == 'user' ? 'You' : 'Local model',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(m.content),
                      ],
                    ),
                  ),
                ),
              ),
              if (controller.busy)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              controller.phase == GenerationPhase.thinking
                                  ? 'Thinking…'
                                  : controller.phase ==
                                        GenerationPhase.cancelling
                                  ? 'Stopping…'
                                  : 'Writing response…',
                            ),
                          ],
                        ),
                        if (controller.draftResponse.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          SelectableText(controller.draftResponse),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (controller.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(controller.error!),
          ),
        if (controller.busy)
          GenerationStatusView(
            phase: controller.phase,
            onStop: controller.cancelGeneration,
          ),

        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  maxLength: 2000,
                  minLines: 1,
                  maxLines: 4,
                  enabled: controller.ready && !controller.busy,
                  decoration: const InputDecoration(
                    hintText: 'Discuss your project with Qwen',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                tooltip: 'Send',
                onPressed: controller.busy || !controller.ready ? null : send,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

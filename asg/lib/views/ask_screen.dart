// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/ask_controller.dart';

class AskScreen extends StatefulWidget {
  const AskScreen({super.key, required this.controller});
  final AskController controller;
  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final input = TextEditingController();
  AskController get controller => widget.controller;
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
    final text = input.text;
    final accepted = await controller.send(text);
    if (mounted && accepted && input.text == text) input.clear();
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !controller.busy && controller.unsavedAnswer == null,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Ask'),
        actions: [
          IconButton(
            tooltip: 'New Ask conversation',
            onPressed: controller.canChangeConversation
                ? () {
                    controller.select(null);
                    input.clear();
                  }
                : null,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Engineering questions · no project required',
                    style: TextStyle(fontSize: 20),
                  ),
                  const SizedBox(height: 8),
                  const Text(AskController.guidance),
                  const SizedBox(height: 8),
                  const Text(
                    'Up to 8,000 characters per question and 24,000 characters of full request context; nothing silently omitted. '
                    'Configured chat output limit; 15 seconds to connect, 30 seconds idle, 3 minutes total. '
                    'Start another conversation when its context is full.',
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      '${controller.selectedId}:${controller.history.length}',
                    ),
                    initialValue: controller.selectedId ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Saved Ask conversations',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('New conversation'),
                      ),
                      ...controller.history.reversed.map(
                        (c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: controller.canChangeConversation
                        ? (id) {
                            controller.select(id == '' ? null : id);
                            input.clear();
                          }
                        : null,
                  ),
                  if (controller.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        controller.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (!controller.ready)
                    TextButton(
                      onPressed: controller.load,
                      child: const Text('Retry loading Ask history'),
                    ),
                  for (final message in controller.messages)
                    AskMessage(role: message.role, text: message.content),
                  if (controller.busy)
                    Text(
                      controller.saving
                          ? 'Saving locally…'
                          : controller.draft.isEmpty
                          ? 'Thinking…'
                          : 'Writing…',
                    ),
                  if (controller.draft.isNotEmpty)
                    AskMessage(
                      role: 'Streaming suggestion',
                      text: controller.draft,
                    ),
                  if (controller.unsavedAnswer != null && !controller.busy) ...[
                    AskMessage(
                      role: 'Unsaved suggestion',
                      text: controller.unsavedAnswer!,
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
                        FilledButton(
                          onPressed: controller.retrySaving,
                          child: const Text('Retry saving'),
                        ),
                        TextButton(
                          onPressed: controller.discardAnswer,
                          child: const Text('Discard unsaved answer'),
                        ),
                      ],
                    ),
                  ],
                  if (controller.canRetryAnswer)
                    TextButton(
                      onPressed: controller.retryAnswer,
                      child: const Text('Retry answer'),
                    ),
                  const SizedBox(height: 16),
                  CallbackShortcuts(
                    bindings: {
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        control: true,
                      ): () {
                        if (controller.canChangeConversation) send();
                      },
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        meta: true,
                      ): () {
                        if (controller.canChangeConversation) send();
                      },
                    },
                    child: TextField(
                      controller: input,
                      enabled: controller.canChangeConversation,
                      minLines: 3,
                      maxLines: 8,
                      maxLength: AskController.inputLimit,
                      decoration: const InputDecoration(
                        labelText: 'Engineering question or pasted code',
                        hintText: 'Ask a question. Ctrl/⌘ + Enter to send.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: controller.canChangeConversation
                            ? send
                            : null,
                        icon: const Icon(Icons.send),
                        label: const Text('Ask model'),
                      ),
                      if (controller.busy)
                        OutlinedButton(
                          onPressed: controller.saving ? null : controller.stop,
                          child: const Text('Stop'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(AskController.stopScope),
                  if (controller.busy || controller.unsavedAnswer != null)
                    const Text(
                      'Stop the request, or save/discard its completed answer, before leaving Ask.',
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class AskMessage extends StatelessWidget {
  const AskMessage({super.key, required this.role, required this.text});
  final String role, text;
  @override
  Widget build(BuildContext context) {
    final chunks = text.split('```');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              role == 'user'
                  ? 'You'
                  : role == 'assistant'
                  ? 'Model suggestion · not tested'
                  : role,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < chunks.length; i++)
              if (chunks[i].trim().isNotEmpty)
                i.isOdd
                    ? Container(
                        padding: const EdgeInsets.all(12),
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SelectableText(
                            chunks[i].trim(),
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                      )
                    : SelectableText(chunks[i].trim()),
          ],
        ),
      ),
    );
  }
}

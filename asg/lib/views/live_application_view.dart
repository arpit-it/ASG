import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/app_definition.dart';

/// Executes the supported application definition as real interactive widgets.
class LiveApplicationView extends StatefulWidget {
  const LiveApplicationView({
    super.key,
    required this.definition,
    this.onStateChanged,
  });
  final AppDefinition definition;
  final ValueChanged<AppDefinition>? onStateChanged;
  @override
  State<LiveApplicationView> createState() => _LiveApplicationViewState();
}

class _LiveApplicationViewState extends State<LiveApplicationView> {
  final items = <String, List<String>>{},
      counters = <String, int>{},
      inputs = <String, TextEditingController>{};
  final noteValues = <String, String>{};
  final completed = <String, Set<int>>{};
  @override
  void initState() {
    super.initState();
    sync(null);
  }

  @override
  void didUpdateWidget(covariant LiveApplicationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync(oldWidget.definition);
  }

  void change(VoidCallback action) {
    setState(action);
    reportState();
  }

  void reportState() {
    widget.onStateChanged?.call(
      AppDefinition(
        title: widget.definition.title,
        theme: widget.definition.theme,
        elements: widget.definition.elements
            .map(
              (e) => AppElement(
                id: e.id,
                kind: e.kind,
                label: e.label,
                items: e.kind == ElementKind.taskList
                    ? List.unmodifiable(items[e.id] ?? e.items)
                    : e.items,
                action: e.action,
                target: e.target,
                value: e.kind == ElementKind.counter
                    ? '${counters[e.id] ?? 0}'
                    : e.kind == ElementKind.notes
                    ? noteValues[e.id] ?? e.value
                    : e.value,
              ),
            )
            .toList(),
      ),
    );
  }

  void sync(AppDefinition? old) {
    final ids = widget.definition.elements.map((e) => e.id).toSet();
    for (final id in inputs.keys.where((id) => !ids.contains(id)).toList()) {
      inputs.remove(id)?.dispose();
    }
    for (final e in widget.definition.elements) {
      final previous = old?.elements
          .where((item) => item.id == e.id)
          .firstOrNull;
      if (e.kind == ElementKind.taskList &&
          (previous == null || !listEquals(previous.items, e.items))) {
        items[e.id] = List.of(e.items);
        completed[e.id] = {};
      }
      if (e.kind == ElementKind.notes &&
          (previous == null || previous.value != e.value)) {
        noteValues[e.id] = e.value;
      }
      if (e.kind == ElementKind.counter &&
          (previous == null || previous.value != e.value)) {
        counters[e.id] = int.tryParse(e.value) ?? 0;
      }
    }
  }

  @override
  void dispose() {
    for (final input in inputs.values) {
      input.dispose();
    }
    super.dispose();
  }

  void add(String id, String text) {
    if (text.trim().isEmpty) return;
    change(() => (items[id] ??= []).add(text.trim()));
  }

  void action(AppElement e) {
    switch (e.action) {
      case AppAction.message:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.value.isEmpty ? e.label : e.value)),
        );
      case AppAction.increment:
        change(() => counters[e.target] = (counters[e.target] ?? 0) + 1);
      case AppAction.clear:
        change(() {
          items[e.target] = [];
          completed[e.target] = {};
        });
      case AppAction.addItem:
        add(e.target, e.value.isEmpty ? 'New item' : e.value);
    }
  }

  Widget element(BuildContext previewContext, AppElement e) {
    switch (e.kind) {
      case ElementKind.heading:
        return Text(
          e.label,
          style: Theme.of(previewContext).textTheme.headlineSmall,
        );
      case ElementKind.text:
        return Text(e.label);
      case ElementKind.button:
        return FilledButton(onPressed: () => action(e), child: Text(e.label));
      case ElementKind.notes:
        return TextFormField(
          key: ValueKey('notes_${e.id}_${e.value}'),
          initialValue: noteValues[e.id] ?? e.value,
          onChanged: (value) {
            noteValues[e.id] = value;
            reportState();
          },
          minLines: 3,
          maxLines: 8,
          decoration: InputDecoration(
            labelText: e.label,
            border: const OutlineInputBorder(),
          ),
        );
      case ElementKind.counter:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.label),
            Row(
              children: [
                IconButton(
                  tooltip: 'Decrease ${e.label}',
                  onPressed: () => setState(
                    () => counters[e.id] = (counters[e.id] ?? 0) - 1,
                  ),
                  icon: const Icon(Icons.remove),
                ),
                Text(
                  '${counters[e.id] ?? 0}',
                  style: const TextStyle(fontSize: 28),
                ),
                IconButton(
                  tooltip: 'Increase ${e.label}',
                  onPressed: () => setState(
                    () => counters[e.id] = (counters[e.id] ?? 0) + 1,
                  ),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ],
        );
      case ElementKind.taskList:
        final input = inputs.putIfAbsent(e.id, TextEditingController.new);
        final list = items[e.id] ?? [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              e.label,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    onSubmitted: (text) {
                      add(e.id, text);
                      input.clear();
                    },
                    decoration: const InputDecoration(
                      hintText: 'Add an item',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Add item',
                  onPressed: () {
                    add(e.id, input.text);
                    input.clear();
                  },
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (list.isEmpty) const Text('No items yet.'),
            ...list.asMap().entries.map(
              (entry) => Row(
                children: [
                  Checkbox(
                    value: completed[e.id]?.contains(entry.key) ?? false,
                    onChanged: (value) => change(() {
                      final done = completed.putIfAbsent(e.id, () => {});
                      value == true
                          ? done.add(entry.key)
                          : done.remove(entry.key);
                    }),
                  ),
                  Expanded(child: Text(entry.value)),
                  IconButton(
                    tooltip: 'Remove item',
                    onPressed: () => change(() {
                      list.removeAt(entry.key);
                      completed[e.id] = {};
                    }),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (widget.definition.theme) {
      'green' => Colors.teal,
      'orange' => Colors.deepOrange,
      'pink' => Colors.pink,
      _ => Colors.indigo,
    };
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: color,
      ),
      child: Material(
        color: const Color(0xfffafafa),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              widget.definition.title,
              style: TextStyle(fontSize: 14, color: color),
            ),
            const Divider(height: 32),
            ...widget.definition.elements.map(
              (e) => Padding(
                key: ValueKey(e.id),
                padding: const EdgeInsets.only(bottom: 20),
                child: Builder(
                  builder: (previewContext) => element(previewContext, e),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

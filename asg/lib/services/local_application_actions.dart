// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/app_definition.dart';

class LocalApplicationChange {
  const LocalApplicationChange(this.definition, this.summary);
  final AppDefinition definition;
  final String summary;
}

/// Applies only fully recognized instructions. Unrecognized requests go to Qwen.
class LocalApplicationActions {
  LocalApplicationChange? apply(AppDefinition current, String instruction) {
    final commands = instruction.trim().split(
      RegExp(r'\s+and\s+|\n', caseSensitive: false),
    );
    if (commands.length > 4) return null;
    var definition = current;
    final summaries = <String>[];
    for (final command in commands) {
      final text = command.trim().replaceFirst(RegExp(r'[.!]+$'), '');
      final theme = RegExp(
        r'^(?:please )?(?:change|set)(?: the)? theme to (indigo|green|orange|pink)$',
        caseSensitive: false,
      ).firstMatch(text);
      final rename = RegExp(
        r'^(?:please )?(?:rename(?: the)? app to|change(?: the)?(?: app)? title to) (.{1,120})$',
        caseSensitive: false,
      ).firstMatch(text);
      final add = RegExp(
        r'^(?:please )?(?:add|create)(?: an?| another)? (counter|notes|task list|todo list)(?: called (.{1,80}))?$',
        caseSensitive: false,
      ).firstMatch(text);
      if (theme != null) {
        final color = theme.group(1)!.toLowerCase();
        definition = AppDefinition(
          title: definition.title,
          theme: color,
          elements: definition.elements,
        );
        summaries.add('Changed the theme to $color.');
      } else if (rename != null) {
        final title = rename.group(1)!.trim();
        if (title.isEmpty) return null;
        definition = AppDefinition(
          title: title,
          theme: definition.theme,
          elements: definition.elements,
        );
        summaries.add('Renamed the app to $title.');
      } else if (add != null && definition.elements.length < 24) {
        final type = add.group(1)!.toLowerCase();
        final kind = type == 'counter'
            ? ElementKind.counter
            : type == 'notes'
            ? ElementKind.notes
            : ElementKind.taskList;
        var suffix = definition.elements.length;
        var id = 'element_$suffix';
        while (definition.elements.any((e) => e.id == id)) {
          id = 'element_${++suffix}';
        }
        final label =
            add.group(2)?.trim() ??
            (kind == ElementKind.counter
                ? 'Counter'
                : kind == ElementKind.notes
                ? 'Notes'
                : 'My tasks');
        definition = AppDefinition(
          title: definition.title,
          theme: definition.theme,
          elements: [
            ...definition.elements,
            AppElement(id: id, kind: kind, label: label),
          ],
        );
        summaries.add('Added $label.');
      } else {
        return null;
      }
    }
    return LocalApplicationChange(
      AppDefinition.fromJson(definition.toJson()),
      summaries.join(' '),
    );
  }
}

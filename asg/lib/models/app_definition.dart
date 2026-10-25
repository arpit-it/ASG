enum ElementKind { heading, text, taskList, counter, notes, button }

enum AppAction { message, increment, clear, addItem }

class AppElement {
  const AppElement({
    required this.id,
    required this.kind,
    required this.label,
    this.items = const [],
    this.completed = const [],
    this.action = AppAction.message,
    this.target = '',
    this.value = '',
  });
  final String id, label, target, value;
  final ElementKind kind;
  final List<String> items;
  final List<int> completed;
  final AppAction action;
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': kind.name,
    'label': label,
    'items': items,
    'completed': completed,
    'action': action.name,
    'target': target,
    'value': value,
  };
  factory AppElement.fromJson(Map<String, dynamic> json) {
    final id = json['id'], type = json['type'], label = json['label'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id) ||
        type is! String ||
        label is! String ||
        label.length > 4000) {
      throw const FormatException('Invalid application element.');
    }
    final kind = ElementKind.values.byName(type);
    final rawItems = json['items'] ?? <String>[];
    if (rawItems is! List ||
        rawItems.length > 100 ||
        rawItems.any((e) => e is! String || e.length > 200)) {
      throw const FormatException('Invalid application items.');
    }
    final completed = json['completed'] ?? <int>[];
    if (completed is! List ||
        completed.any((i) => i is! int || i < 0 || i >= rawItems.length) ||
        completed.toSet().length != completed.length) {
      throw const FormatException('Invalid completed task indexes.');
    }
    final target = json['target'] ?? '', value = json['value'] ?? '';
    if (target is! String ||
        target.length > 64 ||
        value is! String ||
        value.length > 500) {
      throw const FormatException('Invalid action configuration.');
    }
    return AppElement(
      id: id,
      kind: kind,
      label: label,
      items: List.unmodifiable(rawItems.cast<String>()),
      completed: List.unmodifiable(completed.cast<int>()),
      action: AppAction.values.byName(json['action'] as String? ?? 'message'),
      target: target,
      value: value,
    );
  }
}

class AppDefinition {
  const AppDefinition({
    required this.title,
    required this.theme,
    required this.elements,
  });
  final String title, theme;
  final List<AppElement> elements;
  Map<String, dynamic> toJson() => {
    'title': title,
    'theme': theme,
    'elements': elements.map((e) => e.toJson()).toList(),
  };
  factory AppDefinition.fromJson(Map<String, dynamic> json) {
    final title = json['title'],
        theme = json['theme'],
        elements = json['elements'];
    if (title is! String ||
        title.trim().isEmpty ||
        title.length > 120 ||
        !['indigo', 'green', 'orange', 'pink'].contains(theme) ||
        elements is! List ||
        elements.isEmpty ||
        elements.length > 24) {
      throw const FormatException('Invalid application definition.');
    }
    final parsed = elements
        .map((e) => AppElement.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    if (parsed.map((e) => e.id).toSet().length != parsed.length) {
      throw const FormatException('Application element IDs must be unique.');
    }
    for (final e in parsed.where(
      (e) => e.kind == ElementKind.button && e.action != AppAction.message,
    )) {
      final targets = parsed.where((item) => item.id == e.target);
      if (targets.isEmpty ||
          (e.action == AppAction.increment &&
              targets.first.kind != ElementKind.counter) ||
          ([AppAction.clear, AppAction.addItem].contains(e.action) &&
              targets.first.kind != ElementKind.taskList)) {
        throw const FormatException('Button action has an invalid target.');
      }
    }
    return AppDefinition(
      title: title,
      theme: theme as String,
      elements: List.unmodifiable(parsed),
    );
  }
}

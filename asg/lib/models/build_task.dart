/// The fixed starter adapter's complete allowlist. No command text is accepted.
enum BuildOperation { resolve, analyze, test, build }

enum BuildTaskStatus { pending, running, passed, failed, blocked, interrupted }

class BuildTask {
  const BuildTask._(this.operation);
  final BuildOperation operation;
  String get id => 'starter-${operation.name}';
  List<String> get dependencies => operation.index == 0
      ? const []
      : ['starter-${BuildOperation.values[operation.index - 1].name}'];
  static List<BuildTask> get starter =>
      List.unmodifiable(BuildOperation.values.map(BuildTask._));
  Map<String, Object> toJson() => {
    'id': id,
    'operation': operation.name,
    'dependencies': dependencies,
  };

  /// Accept only this adapter's canonical graph, including stable identifiers.
  static List<BuildTask> fromJson(Object? value) {
    if (value is! List || value.length != BuildOperation.values.length) {
      throw const FormatException('Invalid starter task graph.');
    }
    final expected = starter;
    for (var i = 0; i < expected.length; i++) {
      final task = value[i];
      final dependencies = expected[i].dependencies;
      if (task is! Map ||
          task.length != 3 ||
          task['id'] != expected[i].id ||
          task['operation'] != expected[i].operation.name ||
          task['dependencies'] is! List) {
        throw const FormatException('Invalid starter task.');
      }
      final saved = task['dependencies'] as List;
      if (saved.length != dependencies.length ||
          saved.asMap().entries.any((e) => e.value != dependencies[e.key])) {
        throw const FormatException('Invalid starter task dependencies.');
      }
    }
    return expected;
  }
}

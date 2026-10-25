/// The starter adapter's complete allowlist. No command text is accepted.
enum BuildOperation { resolve, analyze, test, build }

enum BuildTaskStatus { pending, running, passed, failed, blocked, interrupted }

class BuildTask {
  BuildTask._(this.id, this.operation, List<String> dependencies)
    : dependencies = List.unmodifiable(dependencies);
  final String id;
  final BuildOperation operation;
  final List<String> dependencies;
  static List<BuildTask> get starter => List.unmodifiable(
    BuildOperation.values.map(
      (operation) => BuildTask._(
        'starter-${operation.name}',
        operation,
        operation.index == 0
            ? []
            : ['starter-${BuildOperation.values[operation.index - 1].name}'],
      ),
    ),
  );
  Map<String, Object> toJson() => {
    'id': id,
    'operation': operation.name,
    'dependencies': dependencies,
  };

  /// One of every allowlisted operation in explicit topological order. Required
  /// prerequisites may be transitive; source checks and tests precede Build.
  static List<BuildTask> fromJson(Object? value) {
    const invalid = FormatException('Invalid starter task graph.');
    if (value is! List || value.length != BuildOperation.values.length) {
      throw invalid;
    }
    final tasks = <BuildTask>[];
    final ancestors = <String, Set<BuildOperation>>{};
    final operations = <BuildOperation>{};
    for (final raw in value) {
      if (raw is! Map ||
          raw.length != 3 ||
          raw['id'] is! String ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$')
              .hasMatch(raw['id'] as String) ||
          raw['operation'] is! String ||
          raw['dependencies'] is! List) {
        throw invalid;
      }
      final id = raw['id'] as String;
      final operation = BuildOperation.values
          .where((o) => o.name == raw['operation'])
          .firstOrNull;
      final dependencies = raw['dependencies'] as List;
      if (operation == null ||
          !operations.add(operation) ||
          ancestors.containsKey(id) ||
          dependencies.length > 3 ||
          dependencies.any((d) => d is! String || !ancestors.containsKey(d)) ||
          dependencies.toSet().length != dependencies.length) {
        throw invalid;
      }
      final prior = <BuildOperation>{
        for (final dependency in dependencies) ...ancestors[dependency]!,
      };
      if ((operation != BuildOperation.resolve &&
              !prior.contains(BuildOperation.resolve)) ||
          (operation == BuildOperation.build &&
              !prior.containsAll([
                BuildOperation.analyze,
                BuildOperation.test,
              ]))) {
        throw invalid;
      }
      ancestors[id] = {...prior, operation};
      tasks.add(BuildTask._(id, operation, dependencies.cast<String>()));
    }
    return List.unmodifiable(tasks);
  }
}

/// The starter adapter's complete allowlist. No command text is accepted.
enum BuildOperation { resolve, analyze, test, build }

enum BuildTaskStatus { pending, running, passed, failed, blocked, interrupted }

class BuildTask {
  BuildTask._(
    this.id,
    this.operation,
    List<String> dependencies, [
    this.boardTaskId,
  ]) : dependencies = List.unmodifiable(dependencies);
  final String id;
  final BuildOperation operation;
  final List<String> dependencies;
  final String? boardTaskId;
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
    'boardTaskId': ?boardTaskId,
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
          raw.length != (raw.containsKey('boardTaskId') ? 4 : 3) ||
          (raw.containsKey('boardTaskId') &&
              (raw['boardTaskId'] is! String ||
                  !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,39}$')
                      .hasMatch(raw['boardTaskId'] as String))) ||
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
      tasks.add(
        BuildTask._(
          id,
          operation,
          dependencies.cast<String>(),
          raw['boardTaskId'] as String?,
        ),
      );
    }
    final references = tasks.map((t) => t.boardTaskId).toList();
    if (references.any((r) => r != null) && references.any((r) => r == null)) {
      throw invalid;
    }
    return List.unmodifiable(tasks);
  }
}

import 'dart:convert';

import 'build_task.dart';

/// A model proposal is data. Only this versioned adapter graph is executable.
class BuildPlan {
  BuildPlan._(this.tasks);
  final List<BuildTask> tasks;

  static String get starterContract =>
      '```asg-build\n${jsonEncode({'version': 1, 'adapter': 'flutter-starter', 'tasks': BuildTask.starter.map((t) => t.toJson()).toList()})}\n```';

  static BuildPlan parse(String content) {
    const message =
        'Build needs one valid structured starter Plan. Request a new '
        'Plan explicitly scoped to generating and verifying the fixed Flutter '
        'web starter, review its tasks, then approve it. Other implementation '
        'plans remain advisory.';
    if (content.length > 65536) throw const FormatException(message);
    // Require standalone fences and reject ambiguous/multiple contracts.
    final markers = RegExp(
      r'^```asg-build[^\r\n]*',
      multiLine: true,
    ).allMatches(content).toList();
    final blocks = RegExp(
      r'^```asg-build\r?\n([\s\S]*?)^```[ \t]*\r?$',
      multiLine: true,
    ).allMatches(content).toList();
    if (markers.length != 1 || blocks.length != 1) {
      throw const FormatException(message);
    }
    try {
      final value = jsonDecode(blocks.single.group(1)!);
      if (value is! Map ||
          value.length != 3 ||
          value['version'] != 1 ||
          value['version'] is! int ||
          value['adapter'] != 'flutter-starter') {
        throw const FormatException(message);
      }
      return BuildPlan._(BuildTask.fromJson(value['tasks']));
    } on FormatException {
      throw const FormatException(message);
    }
  }
}

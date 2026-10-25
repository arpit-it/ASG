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
      final json = blocks.single.group(1)!;
      final value = jsonDecode(json);
      _rejectDuplicateMembers(json);
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

/// Scan validated JSON, decoding keys so escaped spellings share an identity.
/// Strings are consumed as tokens: punctuation inside them cannot alter nesting.
void _rejectDuplicateMembers(String json) {
  final objects = <Set<String>>[];
  for (var i = 0; i < json.length; i++) {
    final char = json[i];
    if (char == '{') {
      objects.add(<String>{});
    } else if (char == '}') {
      objects.removeLast();
    } else if (char == '"') {
      final start = i;
      i++;
      while (json[i] != '"') {
        if (json[i] == r'\') i++;
        i++;
      }
      var next = i + 1;
      while (next < json.length && json[next].trim().isEmpty) {
        next++;
      }
      if (next < json.length && json[next] == ':') {
        final key = jsonDecode(json.substring(start, i + 1)) as String;
        if (!objects.last.add(key)) {
          throw const FormatException('Duplicate Build contract member.');
        }
      }
    }
  }
}

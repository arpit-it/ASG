enum SourceGenerationPhase { generated, verifying, ready, failed }

class GenerationStep {
  const GenerationStep({
    required this.operation,
    required this.exitCode,
    required this.output,
    this.timedOut = false,
  });
  final String operation, output;
  final int exitCode;
  final bool timedOut;
  Map<String, Object> toJson() => {
    'operation': operation,
    'exitCode': exitCode,
    'output': output,
    'timedOut': timedOut,
  };
  factory GenerationStep.fromJson(Map<String, dynamic> json) {
    final step = GenerationStep(
      operation: json['operation'] as String,
      exitCode: json['exitCode'] as int,
      output: json['output'] as String,
      timedOut: json['timedOut'] as bool,
    );
    if (!['resolve', 'analyze', 'test', 'build'].contains(step.operation) ||
        step.output.length > 65536) {
      throw const FormatException('Invalid generation step.');
    }
    return step;
  }
}

class GeneratedProject {
  GeneratedProject({
    required this.directory,
    required this.sdk,
    required this.python,
    required Map<String, String> sources,
    Map<String, String> outputs = const {},
    Map<String, String> resolution = const {},
    List<GenerationStep> steps = const [],
    this.phase = SourceGenerationPhase.generated,
    this.error = '',
  }) : sources = Map.unmodifiable(sources),
       outputs = Map.unmodifiable(outputs),
       resolution = Map.unmodifiable(resolution),
       steps = List.unmodifiable(steps);
  final String directory, sdk, python, error;
  final Map<String, String> sources, outputs, resolution;
  final List<GenerationStep> steps;
  final SourceGenerationPhase phase;
  GeneratedProject copy({
    String? sdk,
    String? python,
    List<GenerationStep>? steps,
    Map<String, String>? outputs,
    Map<String, String>? resolution,
    SourceGenerationPhase? phase,
    String error = '',
  }) => GeneratedProject(
    directory: directory,
    sdk: sdk ?? this.sdk,
    python: python ?? this.python,
    sources: sources,
    outputs: outputs ?? this.outputs,
    resolution: resolution ?? this.resolution,
    steps: steps ?? this.steps,
    phase: phase ?? this.phase,
    error: error,
  );
  Map<String, Object> toJson() => {
    'directory': directory,
    'sdk': sdk,
    'python': python,
    'sources': sources,
    'outputs': outputs,
    'resolution': resolution,
    'steps': steps.map((s) => s.toJson()).toList(),
    'phase': phase.name,
    'error': error,
  };
  factory GeneratedProject.fromJson(Map<String, dynamic> json) {
    final result = GeneratedProject(
      directory: json['directory'] as String,
      sdk: json['sdk'] as String,
      python: json['python'] as String,
      sources: Map<String, String>.from(json['sources'] as Map),
      outputs: Map<String, String>.from(json['outputs'] as Map),
      resolution: Map<String, String>.from(
        json['resolution'] as Map? ?? const {},
      ),
      steps: (json['steps'] as List)
          .map(
            (s) => GenerationStep.fromJson(Map<String, dynamic>.from(s as Map)),
          )
          .toList(),
      phase: SourceGenerationPhase.values.byName(json['phase'] as String),
      error: json['error'] as String,
    );
    if (result.directory.isEmpty ||
        result.sdk.isEmpty ||
        result.python.isEmpty ||
        result.sources.isEmpty ||
        [result.sources, result.outputs, result.resolution].any(
          (files) => files.entries.any(
            (entry) =>
                entry.key.isEmpty ||
                entry.key.startsWith('/') ||
                entry.key
                    .split('/')
                    .any((part) => part == '..' || part == '.') ||
                entry.key.contains('\\') ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value),
          ),
        ) ||
        result.steps.length > 4) {
      throw const FormatException('Invalid generated project record.');
    }
    const operations = ['resolve', 'analyze', 'test', 'build'];
    for (var i = 0; i < result.steps.length; i++) {
      if (result.steps[i].operation != operations[i]) {
        throw const FormatException('Invalid verification history order.');
      }
    }
    if (result.phase == SourceGenerationPhase.ready &&
        (result.steps.length != 4 ||
            result.steps.any((step) => step.exitCode != 0 || step.timedOut) ||
            !result.outputs.containsKey('index.html') ||
            !result.outputs.containsKey('main.dart.js'))) {
      throw const FormatException(
        'A ready outcome requires successful verification and compiled output.',
      );
    }
    return result;
  }
}

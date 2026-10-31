// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

enum ModelSource { local, remote }

/// Auto preserves the original dependency-based choice; it is not a retry policy.
enum RuntimeBackend {
  auto('auto', 'Auto (legacy preference)'),
  mlx('mlx', 'MLX / Metal'),
  torch('torch', 'Torch / MPS');

  const RuntimeBackend(this.argument, this.label);
  final String argument, label;

  static RuntimeBackend parse(Object? value) {
    if (value == null) return RuntimeBackend.auto;
    for (final backend in values) {
      if (value == backend.argument) return backend;
    }
    throw const FormatException('Invalid saved runtime backend.');
  }
}

/// An allowlisted server report, never a local device probe or adequacy claim.
enum LoadedRuntimeDevice {
  mlxMetal('MLX / Metal'),
  torchMps('Torch / MPS');

  const LoadedRuntimeDevice(this.label);
  final String label;

  static LoadedRuntimeDevice? reported(Object? backend, Object? device) =>
      switch ((backend, device)) {
        ('mlx', 'metal') => mlxMetal,
        ('torch', 'mps') => torchMps,
        _ => null,
      };
}

class RuntimeSetup {
  const RuntimeSetup({
    this.python = 'python3',
    this.modelPath = '',
    this.repository = '',
    this.downloadParent = '',
    this.revision = 'main',
    this.backend = RuntimeBackend.auto,
  });
  final String python, modelPath, repository, downloadParent, revision;
  final RuntimeBackend backend;
  Map<String, String> toJson() => {
    'python': python,
    'modelPath': modelPath,
    'repository': repository,
    'downloadParent': downloadParent,
    'revision': revision,
    'backend': backend.argument,
  };
  factory RuntimeSetup.fromJson(Map<String, dynamic> value) => RuntimeSetup(
    python: value['python'] as String,
    modelPath: value['modelPath'] as String,
    repository: value['repository'] as String,
    downloadParent: value['downloadParent'] as String,
    revision: value['revision'] as String? ?? 'main',
    backend: RuntimeBackend.parse(value['backend']),
  );
}

class ModelCandidate {
  const ModelCandidate({
    required this.path,
    required this.name,
    required this.supported,
    required this.detail,
  });
  final String path, name, detail;
  final bool supported;
}

class RuntimeHealth {
  const RuntimeHealth({
    required this.ready,
    required this.detail,
    this.model,
    this.modelPath,
    this.loadedDevice,
  });
  final bool ready;
  final String detail;
  final String? model, modelPath;
  final LoadedRuntimeDevice? loadedDevice;
}

class ModelRepository {
  const ModelRepository._(this.location, this.name, this.huggingFace);
  final String location, name;
  final bool huggingFace;
  factory ModelRepository.parse(String input) {
    final text = input.trim();
    final id = RegExp(
      r'^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$',
    );
    if (id.hasMatch(text)) {
      return ModelRepository._(text, text.split('/').last, true);
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.hasPort ||
        uri.pathSegments.any((p) => p == '..' || p == '.')) {
      throw const FormatException(
        'Enter owner/model or a public HTTPS Git repository URL without credentials.',
      );
    }
    final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (uri.host == 'huggingface.co' && parts.length == 2) {
      final repo =
          '${parts[0]}/${parts[1].replaceFirst(RegExp(r'\.git$'), '')}';
      if (!id.hasMatch(repo)) {
        throw const FormatException('Invalid Hugging Face repository.');
      }
      return ModelRepository._(repo, repo.split('/').last, true);
    }
    if (parts.length < 2 ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(parts.last)) {
      throw const FormatException('Enter a model repository URL.');
    }
    final name = parts.last.replaceFirst(RegExp(r'\.git$'), '');
    if (name.isEmpty || name == '.' || name == '..') {
      throw const FormatException('Invalid repository name.');
    }
    return ModelRepository._(uri.toString(), name, false);
  }
}

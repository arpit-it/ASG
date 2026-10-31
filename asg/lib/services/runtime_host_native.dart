// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/runtime_setup.dart';
import '../models/runtime_capabilities.dart';
import 'runtime_host.dart';

RuntimeHost createRuntimeHost() => _host;
final _host = NativeRuntimeHost();

class NativeRuntimeHost implements RuntimeHost {
  NativeRuntimeHost({
    this.port = 8765,
    this.supportDirectory,
    this.loadAsset,
    this.discoveryTimeout = const Duration(seconds: 10),
  });
  final Duration discoveryTimeout;
  final int port;
  final Future<Directory> Function()? supportDirectory;
  final Future<String> Function(String)? loadAsset;
  final _events = StreamController<String>.broadcast();
  Process? _process;
  bool _loading = false, _working = false;
  @override
  bool get supported => Platform.isMacOS;
  @override
  bool get ownsProcess => _process != null;
  @override
  bool get loading => _loading;
  @override
  bool get working => _working;
  @override
  Stream<String> get events => _events.stream;
  void _check() {
    if (!supported) {
      throw UnsupportedError('Managed inference currently requires macOS.');
    }
  }

  @override
  Future<String?> chooseDirectory() async {
    _check();
    return getDirectoryPath();
  }

  @override
  Future<String?> choosePython() async {
    _check();
    return (await openFile())?.path;
  }

  Future<Directory> _support() async {
    final createDirectory = supportDirectory;
    if (createDirectory != null) return createDirectory();
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/runtime').create(recursive: true);
  }

  Future<String> _script(String name) async {
    final root = await _support();
    final file = File('${root.path}/$name');
    await file.writeAsString(
      await (loadAsset?.call(name) ?? rootBundle.loadString('tools/$name')),
      flush: true,
    );
    return file.path;
  }

  void _log(String value) {
    _events.add(value.length > 600 ? value.substring(0, 600) : value);
  }

  void _observe(Process process) {
    for (final stream in [process.stdout, process.stderr]) {
      var reported = false;
      // Child output is untrusted and may contain prompts, credentials or paths.
      // Consume bytes without decoding or forwarding them, with one activity
      // notice per stream so verbose processes cannot flood the setup log.
      stream.listen((bytes) {
        if (bytes.isEmpty || reported) return;
        reported = true;
        _log(
          'Runtime process output received. Raw output is hidden for privacy.',
        );
      }, onError: (_) => _log('Runtime output could not be read.'));
    }
  }

  Future<void> _run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(minutes: 3),
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
      runInShell: false,
    );
    _observe(process);
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw TimeoutException(
          'Operation timed out; partial files were retained.',
        );
      },
    );
    if (code != 0) {
      throw StateError('Operation failed (exit $code). Check the setup log.');
    }
  }

  Future<T> _job<T>(Future<T> Function() action) async {
    _check();
    if (_working) {
      throw StateError('A runtime operation is already in progress.');
    }
    _working = true;
    try {
      return await action();
    } finally {
      _working = false;
    }
  }

  @override
  Future<List<ModelCandidate>> scan(String path) => _job(() async {
    final root = Directory(path.trim());
    if (!await root.exists()) {
      throw const FormatException(
        'Select an existing model folder or repository.',
      );
    }
    final canonical = await root.resolveSymbolicLinks();
    final directories = <String>[canonical];
    // Bounded scanning finds models in a repository or model collection.
    var frontier = <String>[canonical];
    for (var depth = 0; depth < 3 && directories.length < 200; depth++) {
      final next = <String>[];
      for (final parent in frontier) {
        await for (final entry in Directory(parent).list(followLinks: false)) {
          if (entry is Directory &&
              !entry.path.split(Platform.pathSeparator).last.startsWith('.')) {
            directories.add(entry.path);
            next.add(entry.path);
            if (directories.length >= 200) break;
          }
        }
        if (directories.length >= 200) break;
      }
      frontier = next;
    }
    final result = <ModelCandidate>[];
    for (final folder in directories) {
      final config = File('$folder/config.json');
      if (!await config.exists()) continue;
      try {
        if (await config.length() > 1024 * 1024) {
          throw const FormatException('Configuration file too large.');
        }
        final data =
            jsonDecode(await config.readAsString()) as Map<String, dynamic>;
        final architecture = data['architectures'];
        final known =
            architecture is List &&
            architecture.length == 1 &&
            architecture.single == 'Qwen3_5ForConditionalGeneration';
        String? problem;
        if (!known) problem = 'Unsupported architecture. Initial managed runtime supports Qwen3.5 Transformers checkpoints.';
        final indexFile = File('$folder/model.safetensors.index.json');
        final files = <String>[];
        if (await indexFile.exists()) {
          if (await indexFile.length() > 8 * 1024 * 1024) {
            throw const FormatException('Weight index too large.');
          }
          final index = jsonDecode(
            await indexFile.readAsString(),
          ) as Map<String, dynamic>;
          files.addAll(
            (index['weight_map'] as Map).values.cast<String>().toSet(),
          );
        } else {
          files.add('model.safetensors');
        }
        if (files.isEmpty) problem = 'Weight index contains no shards.';
        for (final name in [
          ...files,
          'tokenizer.json',
          'tokenizer_config.json',
        ]) {
          if (name.startsWith('/') ||
              name.replaceAll('\\', '/').split('/').contains('..')) {
            throw const FormatException('Unsafe model file path.');
          }
          final file = File('$folder/$name');
          if (!await file.exists()) {
            problem = 'Required checkpoint files are missing. Download the complete model, not just its config.';
            break;
          }
          final resolved = await file.resolveSymbolicLinks();
          if (!resolved.startsWith('$folder/')) {
            problem = 'Linked model files outside the checkpoint folder are not supported. Select a self-contained downloaded checkpoint.';
            break;
          }
          if (await file.length() < 512 && name.endsWith('.safetensors')) {
            problem = 'Weights are empty or Git LFS pointers. Download actual model weights.';
            break;
          }
        }
        result.add(
          ModelCandidate(
            path: folder,
            name: folder.split(Platform.pathSeparator).last,
            supported: problem == null && known,
            quantized:
                data['quantization'] != null ||
                data['quantization_config'] != null,
            detail:
                problem ?? 'Qwen3.5 · complete local Safetensors checkpoint',
          ),
        );
      } catch (_) {
        result.add(
          ModelCandidate(
            path: folder,
            name: folder.split(Platform.pathSeparator).last,
            supported: false,
            detail: 'Model metadata could not be validated. Check config.json and the weight index, then select a complete compatible checkpoint.',
          ),
        );
      }
    }
    if (result.isEmpty) {
      throw const FormatException(
        'No Transformers config.json found. Choose the complete checkpoint folder; a standalone weight file is insufficient. GGUF/MLX runtimes are not yet supported.',
      );
    }
    return result;
  });
  @override
  Future<RuntimeCapabilities> discover(String python) => _job(() async {
    if (python.trim().isEmpty) {
      throw const FormatException('Choose a Python interpreter.');
    }
    await _script('qwen_backends.py');
    final script = await _script('qwen_server.py');
    final process = await Process.start(python.trim(), [
      '-B',
      script,
      '--capabilities',
    ], runInShell: false);
    var exited = false;
    final exit = process.exitCode.then((code) {
      exited = true;
      return code;
    });
    final bytes = <int>[];
    var overflow = false;
    var outputFailed = false;
    final outputDone = Completer<void>();
    final errorsDone = Completer<void>();
    final output = process.stdout.listen(
      (chunk) {
        if (bytes.length + chunk.length > 65536) {
          overflow = true;
          process.kill(ProcessSignal.sigkill);
        } else if (!overflow) {
          bytes.addAll(chunk);
        }
      },
      onDone: () {
        if (!outputDone.isCompleted) outputDone.complete();
      },
      onError: (_) {
        outputFailed = true;
        process.kill(ProcessSignal.sigkill);
        if (!outputDone.isCompleted) outputDone.complete();
      },
    );
    // Consume without retaining stderr, which can contain private environment data.
    final errors = process.stderr.listen(
      (_) {},
      onDone: () {
        if (!errorsDone.isCompleted) errorsDone.complete();
      },
      onError: (_) {
        outputFailed = true;
        if (!errorsDone.isCompleted) errorsDone.complete();
      },
    );
    try {
      final result = await Future.wait<Object?>([
        exit,
        outputDone.future,
        errorsDone.future,
      ]).timeout(discoveryTimeout);
      final code = result.first;
      if (code != 0 || overflow || outputFailed) {
        throw StateError(
          'Capability discovery failed. Check the Python environment and retry.',
        );
      }
      return RuntimeCapabilities.fromJson(jsonDecode(utf8.decode(bytes)));
    } finally {
      try {
        if (!exited) {
          process.kill(ProcessSignal.sigkill);
          await exit.timeout(const Duration(seconds: 2));
        }
      } finally {
        await output.cancel();
        await errors.cancel();
      }
    }
  });
  @override
  Future<void> prepare(String python) => _job(() async {
    if (python.trim().isEmpty) {
      throw const FormatException('Choose a Python interpreter.');
    }
    final support = await _support();
    await _run(python, [
      '-c',
      r'''import importlib.util, sys, subprocess
if importlib.util.find_spec("mlx_lm"):
    import mlx.core as mx
    from mlx_lm import load, stream_generate
    print("MLX streaming runtime ready; no helper installation needed.")
else:
    import torch
    from transformers import Qwen3_5ForConditionalGeneration
    assert torch.backends.mps.is_available(), "Apple Metal unavailable"
    subprocess.run([sys.executable, "-m", "pip", "install", "--no-deps", "--target", sys.argv[1], "accelerate==1.15.0"], check=True)
    print("Legacy Torch runtime prepared. A local 4-bit MLX model is recommended for lower memory and faster inference.")
''',
      '${support.path}/.runtime-deps',
    ]);
    _log('Runtime environment checked. Existing packages were not replaced.');
  });
  @override
  Future<String> download(RuntimeSetup setup) => _job(() async {
    final repo = ModelRepository.parse(setup.repository);
    if (setup.downloadParent.trim().isEmpty ||
        !await Directory(setup.downloadParent).exists()) {
      throw const FormatException('Choose an existing download destination.');
    }
    if (setup.revision.trim().isEmpty || setup.revision.startsWith('-')) {
      throw const FormatException('Enter a revision or branch.');
    }
    final parent = await Directory(setup.downloadParent).resolveSymbolicLinks();
    final destination = Directory('$parent/${repo.name}');
    if (await destination.exists()) {
      throw StateError(
        'Destination already exists. Choose its files using Local files, or select a different parent. Existing folders are never overwritten.',
      );
    }
    if (repo.huggingFace) {
      final script = await _script('download_model.py');
      await _run(setup.python, [
        script,
        '--repository',
        repo.location,
        '--revision',
        setup.revision,
        '--destination',
        destination.path,
      ], timeout: const Duration(hours: 6));
    } else {
      await _run(
        'git',
        [
          '-c',
          'core.hooksPath=/dev/null',
          'clone',
          '--depth',
          '1',
          '--branch',
          setup.revision,
          '--',
          repo.location,
          destination.path,
        ],
        timeout: const Duration(hours: 6),
        environment: {
          'GIT_TERMINAL_PROMPT': '0',
          'GIT_CONFIG_GLOBAL': '/dev/null',
          'GIT_CONFIG_SYSTEM': '/dev/null',
        },
      );
      _log(
        'Git clone finished. LFS pointers will be rejected during validation; use the Hugging Face URL for LFS-hosted models.',
      );
    }
    _log('Download finished. Validating local checkpoint next.');
    return destination.path;
  });
  @override
  Future<void> start(RuntimeSetup setup, String modelId) => _job(() async {
    if (_process != null) {
      throw StateError(
        'Stop the runtime started by this app before starting another.',
      );
    }
    // Reserve/check the fixed managed port before loading any large weights.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
    // The inference bridge imports this sibling module after asset extraction.
    await _script('qwen_backends.py');
    final script = await _script('qwen_server.py');
    final process = await Process.start(setup.python, [
      '-B',
      script,
      '--backend',
      setup.backend.argument,
      '--model',
      setup.modelPath,
      '--port',
      '$port',
      '--model-id',
      modelId,
      '--parent-pid',
      '$pid',
    ], runInShell: false);
    _process = process;
    _loading = true;
    _observe(process);
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          _loading = false;
          _log('Runtime exited ($code).');
        }
      }),
    );
    _log('Runtime process started. Waiting for model readiness…');
  });
  void markReady() {
    _loading = false;
  }

  @override
  Future<void> stop() async {
    _check();
    final process = _process;
    if (process == null) {
      throw StateError(
        'This app does not own the running runtime. Stop externally started runtimes in their terminal.',
      );
    }
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return process.exitCode;
      },
    );
    _process = null;
    _loading = false;
    _log('Managed runtime stopped.');
  }
}

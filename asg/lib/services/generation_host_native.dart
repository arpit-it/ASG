// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../models/app_definition.dart';
import '../models/generation_capabilities.dart';
import '../models/artifact_inspection.dart';
import '../models/build_task.dart';
import '../models/project.dart';
import '../models/requirements_board.dart';
import '../models/named_flutter_test_result.dart';
import '../models/source_generation.dart';
import 'flutter_source_template.dart';
import 'generation_host.dart';
import 'named_test_session.dart';

GenerationHost createGenerationHost() => NativeGenerationHost();

class NativeGenerationHost
    implements
        GenerationHost,
        ArtifactInspector,
        NamedTestSession,
        GenerationCapabilitySource {
  NativeGenerationHost({
    this.loadAsset = _loadAsset,
    Future<GenerationStep> Function(GeneratedProject, String)? runOperation,
  }) : _operationOverride = runOperation;
  final Future<String> Function(String) loadAsset;
  final Future<GenerationStep> Function(GeneratedProject, String)?
  _operationOverride;
  bool _closed = false;
  Process? _activeProcess;
  bool _verificationCancelled = false;
  @override
  void cancelVerification() {
    _verificationCancelled = true;
    _activeProcess?.kill(ProcessSignal.sigterm);
  }

  void checkVerification() {
    checkOpen();
    if (_verificationCancelled) {
      throw StateError(
        'Verification stopped by user. Existing files are retained.',
      );
    }
  }

  void checkOpen() {
    if (_closed) throw StateError('Generation session closed.');
  }

  HttpServer? _server;
  Uri? _preview;
  @override
  bool get supported => Platform.isMacOS;
  @override
  GenerationCapabilities get capabilities => Platform.isMacOS
      ? const GenerationCapabilities.macOS()
      : GenerationCapabilities.unavailable(switch (Platform.operatingSystem) {
          'linux' => 'Linux',
          'windows' => 'Windows',
          'android' => 'Android',
          'ios' => 'iOS',
          _ => 'Unsupported native host',
        });
  static Future<String> _loadAsset(String name) => rootBundle.loadString(name);

  @override
  Future<GeneratedProject> generate({
    required StudioProject project,
    required AppDefinition definition,
    required String parent,
    required String name,
    required String sdk,
    required String python,
    void Function()? authorizeWrite,
  }) async {
    void checkWrite() {
      checkOpen();
      authorizeWrite?.call();
    }

    checkWrite();
    if (project.type != 'Flutter') {
      throw UnsupportedError('Only the Flutter template is available.');
    }
    if (!RegExp(r'^[a-z][a-z0-9_]{2,50}$').hasMatch(name)) {
      throw const FormatException(
        'Use 3–51 lowercase letters, digits or underscores for a new folder.',
      );
    }
    if (!path.isAbsolute(parent) ||
        !path.isAbsolute(sdk) ||
        python.trim().isEmpty) {
      throw const FormatException(
        'Choose absolute project parent and Flutter SDK directories and a Python executable.',
      );
    }
    final canonicalParent = await Directory(parent).resolveSymbolicLinks();
    final canonicalSdk = await Directory(sdk).resolveSymbolicLinks();
    if (path.normalize(parent) != canonicalParent ||
        path.normalize(sdk) != canonicalSdk) {
      throw const FormatException(
        'Choose real directories, not symbolic links.',
      );
    }
    if (!await File(path.join(canonicalSdk, 'bin', 'flutter')).exists()) {
      throw const FormatException(
        'The selected SDK has no bin/flutter executable.',
      );
    }
    final destination = path.join(canonicalParent, name);
    if (!path.isWithin(canonicalParent, destination) ||
        await FileSystemEntity.type(destination, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw StateError(
        'Destination already exists. Choose a new folder; nothing was overwritten.',
      );
    }
    // Exclusive single-directory creation prevents races with an existing file.
    checkWrite();
    final created = await Process.run('/bin/mkdir', [
      destination,
    ], runInShell: false).timeout(const Duration(seconds: 5));
    if (created.exitCode != 0) {
      throw StateError(
        'A new directory could not be created. Check parent permissions or choose a different new name; nothing was overwritten.',
      );
    }
    if (await Directory(destination).resolveSymbolicLinks() != destination) {
      throw StateError('Destination changed during creation.');
    }
    checkOpen();
    final files = flutterSourceTemplate(
      project,
      definition,
      await loadAsset('lib/models/app_definition.dart'),
      await loadAsset('assets/legal/ASG_NOTICES.txt'),
    );
    checkWrite();
    for (final entry in files.entries) {
      checkWrite();
      final file = File(path.join(destination, entry.key));
      await file.parent.create(recursive: true);
      checkWrite();
      await file.create(exclusive: true);
      checkWrite();
      await file.writeAsString(entry.value, flush: true);
    }
    return GeneratedProject(
      directory: destination,
      sdk: canonicalSdk,
      python: python,
      sources: await fingerprints(destination, source: true),
    );
  }

  static Future<Map<String, String>> fingerprints(
    String directory, {
    required bool source,
  }) => Isolate.run(() async {
    final root = Directory(directory);
    if (await root.resolveSymbolicLinks() != directory) {
      throw StateError('Generated project path changed.');
    }
    final values = <String, String>{};
    Future<void> visit(Directory folder) async {
      await for (final entity in folder.list(followLinks: false)) {
        final relative = path
            .relative(entity.path, from: directory)
            .replaceAll(path.separator, '/');
        if (source &&
            (relative == 'build' ||
                relative == '.dart_tool' ||
                relative == 'pubspec.lock')) {
          continue;
        }
        if (entity is Link) {
          throw StateError(
            'Symbolic links are not accepted in generated output.',
          );
        }
        if (entity is Directory) {
          await visit(entity);
        } else if (entity is File) {
          values[relative] = sha256
              .convert(await entity.readAsBytes())
              .toString();
        } else {
          throw StateError('Unsupported generated filesystem entry.');
        }
      }
    }

    await visit(root);
    return values;
  });

  static bool sameFiles(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
  Future<void> checkSources(GeneratedProject project) async {
    checkOpen();
    if (!sameFiles(
      project.sources,
      await fingerprints(project.directory, source: true),
    )) {
      throw StateError(
        'Generated source changed. Verification will not execute modified or unexpected source. Generate into a new folder instead.',
      );
    }
    for (final folder in ['.dart_tool', 'build']) {
      if (await FileSystemEntity.type(
            path.join(project.directory, folder),
            followLinks: false,
          ) ==
          FileSystemEntityType.link) {
        throw StateError('Linked build/cache directories are not accepted.');
      }
    }
  }

  static Future<Map<String, String>> resolutionFiles(
    GeneratedProject project,
  ) async {
    final values = <String, String>{};
    for (final relative in [
      'pubspec.lock',
      '.dart_tool/package_config.json',
      '.dart_tool/package_graph.json',
    ]) {
      final file = File(path.join(project.directory, relative));
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Linked dependency metadata is not accepted.');
      }
      if (await file.exists()) {
        values[relative] = sha256.convert(await file.readAsBytes()).toString();
      }
    }
    return values;
  }

  Future<void> checkResolution(GeneratedProject project) async {
    if (!sameFiles(project.resolution, await resolutionFiles(project))) {
      throw StateError(
        'Dependency resolution metadata changed or was interrupted. Generate a new folder instead of executing changed inputs.',
      );
    }
  }

  @override
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  }) async {
    if (_commandRunning) throw StateError('A command is already running.');
    _verificationCancelled = false;
    // Validate even programmatically constructed snapshots before trusting a prefix.
    if (resume) {
      GeneratedProject.fromJson(project.toJson());
      final refusal = project.resumeRefusal;
      if (refusal != null) throw StateError('Resume refused. $refusal');
    }
    if (!path.isAbsolute(project.sdk) ||
        project.python.trim().isEmpty ||
        await Directory(project.sdk).resolveSymbolicLinks() !=
            path.normalize(project.sdk) ||
        !await File(path.join(project.sdk, 'bin', 'flutter')).exists()) {
      throw const FormatException(
        'Select a real, installed Flutter SDK and Python executable.',
      );
    }
    await checkSources(project);
    await checkResolution(project);
    var current = project.copy(
      sdk: path.normalize(project.sdk),
      phase: SourceGenerationPhase.verifying,
      steps: resume ? project.steps : const [],
      checkpointVersion: 1,
      failedOperation: '',
      pendingOperation: '',
      outputs: const {},
    );
    await progress(current);
    // Legacy snapshots retain the same trusted fixed adapter. New snapshots
    // carry its validated named graph in sequential dependency order alongside
    // their exact authorizing approval.
    for (final task in (project.tasks ?? BuildTask.starter).skip(
      current.steps.length,
    )) {
      final operation = task.operation.name;
      late GenerationStep result;
      try {
        // Validation refusal belongs to this task even when no command starts.
        // Preserve completed steps and never fabricate an exit result.
        await checkSources(project);
        if (operation != 'resolve') await checkResolution(current);
        checkVerification();
      } catch (error) {
        await progress(
          current.copy(
            phase: SourceGenerationPhase.failed,
            failedOperation: operation,
            error: '$operation validation failed before execution. $error',
          ),
        );
        rethrow;
      }
      // Approval/persistence refusal must remain outside the validation catch.
      // Revalidate durable consent before starting each trusted command.
      await progress(current);
      checkVerification();
      Future<void> checkpoint() async {
        current = current.copy(pendingOperation: operation);
        await progress(current);
        checkVerification();
      }

      try {
        if (_operationOverride != null) await checkpoint();
        result = _operationOverride != null
            ? await _operationOverride(project, operation)
            : await runFlutterOperation(
                project,
                operation,
                beforeStart: checkpoint,
              );
      } catch (error) {
        // A runner exception has no trustworthy exit result. Keep completed
        // evidence and identify the task separately from GenerationStep.
        current = current.copy(
          phase: SourceGenerationPhase.failed,
          failedOperation: operation,
          error: '$operation could not complete. $error',
        );
        await progress(current);
        rethrow;
      }
      checkOpen();
      if (_verificationCancelled && !result.cancelled) {
        result = GenerationStep(
          operation: result.operation,
          exitCode: result.exitCode,
          output: result.output,
          timedOut: result.timedOut,
          outputLimitExceeded: result.outputLimitExceeded,
          cancelled: true,
        );
      }
      current = current.copy(
        steps: [...current.steps, result],
        pendingOperation: '',
      );
      if (!result.succeeded) {
        current = current.copy(
          phase: SourceGenerationPhase.failed,
          error: result.cancelled
              ? '$operation was cancelled. Verification stopped.'
              : result.outputLimitExceeded
              ? '$operation exceeded the 64 KiB output limit. Verification stopped.'
              : '$operation failed. Inspect its output and retry verification after fixing the installed toolchain.',
        );
        await progress(current);
        return current;
      }
      if (operation == 'resolve') {
        try {
          current = current.copy(resolution: await resolutionFiles(project));
        } catch (_) {
          // Metadata rejection must retain the command's actual result. Keep
          // the prior fingerprint so a retry cannot trust the rejected input.
          await progress(current);
          rethrow;
        }
      }
      await progress(current);
    }
    checkVerification();
    await checkSources(project);
    final output = path.join(project.directory, 'build', 'web');
    final outputs = await fingerprints(output, source: false);
    if (!outputs.containsKey('index.html') ||
        !outputs.containsKey('main.dart.js')) {
      throw StateError('Flutter did not produce a complete web build.');
    }
    checkVerification();
    current = current.copy(
      phase: SourceGenerationPhase.ready,
      outputs: outputs,
    );
    await progress(current);
    return current;
  }

  Future<GenerationStep> runFlutterOperation(
    GeneratedProject project,
    String operation, {
    Future<void> Function()? beforeStart,
  }) async {
    final data = await _runFlutterCommand(
      project,
      operation,
      beforeStart: beforeStart,
    );
    return GenerationStep(
      operation: operation,
      exitCode: data['exitCode'] as int,
      output: data['output'] as String,
      timedOut: data['timedOut'] as bool,
      outputLimitExceeded: data['outputLimitExceeded'] as bool,
      cancelled: data['cancelled'] as bool,
    );
  }

  @override
  Future<ArtifactInspection> inspectNamedTestInputs(
    GeneratedProject project,
  ) async {
    try {
      await checkSources(project);
      await checkResolution(project);
      return await inspectArtifacts(project);
    } catch (_) {
      return ArtifactInspection.unavailable;
    }
  }

  /// Command evidence only; callers must bind it to durable inputs separately.
  @override
  Future<NamedFlutterTestResult> runNamedFlutterTest(
    GeneratedProject project,
    FlutterTestTarget target, {
    required Future<void> Function() beforeStart,
  }) async {
    target.validate();
    if (!project.confined) {
      throw StateError('Named tests require confined execution.');
    }
    final data = await _runFlutterCommand(
      project,
      'test',
      target: target,
      beforeStart: beforeStart,
    );
    checkVerification();
    return NamedFlutterTestResult.fromCommand(data, target);
  }

  Future<Map<String, dynamic>> _runFlutterCommand(
    GeneratedProject project,
    String operation, {
    FlutterTestTarget? target,
    Future<void> Function()? beforeStart,
  }) async {
    if (_commandRunning) throw StateError('A command is already running.');
    _commandRunning = true;
    try {
      return await _dispatchFlutterCommand(
        project,
        operation,
        target: target,
        beforeStart: beforeStart,
      );
    } finally {
      _commandRunning = false;
    }
  }

  bool _commandRunning = false;
  Future<Map<String, dynamic>> _dispatchFlutterCommand(
    GeneratedProject project,
    String operation, {
    FlutterTestTarget? target,
    Future<void> Function()? beforeStart,
  }) async {
    checkVerification();
    if (!['resolve', 'analyze', 'test', 'build'].contains(operation)) {
      throw ArgumentError('Unapproved generation operation.');
    }
    for (final relative in [
      'bin/cache/flutter_tools.snapshot',
      'bin/cache/dart-sdk/bin/dart',
      'packages/flutter_tools/.dart_tool/package_config.json',
    ]) {
      if (!await File(path.join(project.sdk, relative)).exists()) {
        throw StateError(
          'Use an already initialized Flutter SDK with cached tools and Dart. ASG will not bootstrap an SDK.',
        );
      }
    }
    final helperDirectory = await Directory.systemTemp.createTemp(
      'asg-command-',
    );
    Process? process;
    try {
      final helper = File(
        path.join(helperDirectory.path, 'generation_command.py'),
      );
      await helper.writeAsString(
        await loadAsset('tools/generation_command.py'),
        flush: true,
      );
      // Helper preparation has async gaps. Check consent again at the actual
      // launch boundary; no further awaits occur before starting the process.
      await beforeStart?.call();
      checkVerification();
      process = await Process.start(project.python, [
        '-I',
        '-B',
        helper.path,
        '--operation',
        operation,
        '--sdk',
        project.sdk,
        '--directory',
        project.directory,
        '--timeout',
        '${project.limits.commandTimeoutSeconds}',
        '--output-limit',
        '${project.limits.outputLimitBytes}',
        if (project.confined) '--confined',
        if (target != null) ...[
          '--test-file',
          target.file,
          '--test-name',
          target.name,
        ],
      ], runInShell: false);
      _activeProcess = process;
      if (_closed || _verificationCancelled) {
        process.kill(ProcessSignal.sigterm);
      }
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final code = await process.exitCode.timeout(
        Duration(seconds: project.limits.commandTimeoutSeconds + 10),
        onTimeout: () {
          process?.kill(ProcessSignal.sigterm);
          throw const FormatException(
            'Generation helper exceeded its deadline.',
          );
        },
      );
      final out = await stdout;
      final error = await stderr;
      if (code != 0) {
        if (target != null) {
          throw const FormatException(
            'Named test helper did not return evidence.',
          );
        }
        return {
          'exitCode': code,
          'output': error.substring(0, min(error.length, 65536)),
          'timedOut': false,
          'outputLimitExceeded': false,
          'cancelled': false,
        };
      }
      return jsonDecode(out) as Map<String, dynamic>;
    } finally {
      if (process != null) {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            process?.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      }
      _activeProcess = null;
      await helperDirectory.delete(recursive: true);
    }
  }

  @override
  Future<ArtifactInspection> inspectArtifacts(GeneratedProject project) async {
    if (project.phase != SourceGenerationPhase.ready ||
        project.sources.isEmpty ||
        project.outputs.isEmpty) {
      return ArtifactInspection.unverified;
    }
    try {
      checkOpen();
      final sources = await fingerprints(project.directory, source: true);
      final outputs = await fingerprints(
        path.join(project.directory, 'build', 'web'),
        source: false,
      );
      checkOpen();
      if (project.sources.keys.any((key) => !sources.containsKey(key)) ||
          project.outputs.keys.any((key) => !outputs.containsKey(key))) {
        return ArtifactInspection.missing;
      }
      return sameFiles(project.sources, sources) &&
              sameFiles(project.outputs, outputs)
          ? ArtifactInspection.matching
          : ArtifactInspection.stale;
    } on FileSystemException catch (error) {
      // ENOENT only: permissions and other I/O errors remain unavailable.
      return error.osError?.errorCode == 2
          ? ArtifactInspection.missing
          : ArtifactInspection.unavailable;
    } catch (_) {
      return ArtifactInspection.unavailable;
    }
  }

  static Future<List<int>?> verifiedBytes(String filename, String digest) =>
      Isolate.run(() async {
        final bytes = await File(filename).readAsBytes();
        return sha256.convert(bytes).toString() == digest ? bytes : null;
      });

  @override
  Future<Uri> startPreview(GeneratedProject project) async {
    if (project.phase != SourceGenerationPhase.ready) {
      throw StateError('A successful build is required.');
    }
    await checkSources(project);
    final output = path.join(project.directory, 'build', 'web');
    if (!sameFiles(
      project.outputs,
      await fingerprints(output, source: false),
    )) {
      throw StateError('Built output changed. Verify again before previewing.');
    }
    await stopPreview();
    final token = List.generate(
      24,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    checkOpen();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('Generation session closed.');
    }
    _server = server;
    final origin = 'http://127.0.0.1:${server.port}';
    _preview = Uri.parse('$origin/$token/');
    server.listen((request) async {
      try {
        final segments = request.uri.pathSegments;
        if (!['GET', 'HEAD'].contains(request.method) ||
            segments.isEmpty ||
            segments.first != token ||
            (request.headers.value('sec-fetch-site') == 'cross-site' &&
                !(request.headers.value('sec-fetch-mode') == 'navigate' &&
                    request.headers.value('sec-fetch-dest') == 'document')) ||
            (request.headers.value('origin') != null &&
                request.headers.value('origin') != origin)) {
          request.response.statusCode = HttpStatus.forbidden;
          return;
        }
        final relative = segments.skip(1).where((s) => s.isNotEmpty).join('/');
        if (segments.any(
          (s) =>
              s == '..' ||
              s == '.' ||
              s.contains('\\') ||
              s.contains('/') ||
              s.contains('\u0000'),
        )) {
          request.response.statusCode = 403;
          return;
        }
        final fileName = relative.isEmpty ? 'index.html' : relative;
        if (!project.outputs.containsKey(fileName)) {
          request.response.statusCode = 404;
          return;
        }
        final file = File(path.join(output, fileName));
        if (!path.isWithin(output, await file.resolveSymbolicLinks())) {
          request.response.statusCode = 403;
          return;
        }
        final bytes = await verifiedBytes(
          file.path,
          project.outputs[fileName]!,
        );
        if (bytes == null) {
          request.response.statusCode = 409;
          return;
        }
        request.response.headers.set('Cache-Control', 'no-store');
        if (project.confined) {
          request.response.headers.set(
            'Content-Security-Policy',
            "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
                "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
                "font-src 'self' data:; connect-src 'self'; worker-src 'self' blob:; "
                "base-uri 'self'; frame-ancestors 'none'; form-action 'none'",
          );
        }
        request.response.headers.set('X-Content-Type-Options', 'nosniff');
        request.response.headers.contentType = ContentType.parse(switch (path
            .extension(fileName)) {
          '.html' => 'text/html; charset=utf-8',
          '.js' || '.mjs' => 'application/javascript',
          '.json' => 'application/json',
          '.wasm' => 'application/wasm',
          '.css' => 'text/css',
          '.ttf' => 'font/ttf',
          '.woff2' => 'font/woff2',
          '.png' => 'image/png',
          _ => 'application/octet-stream',
        });
        if (request.method == 'GET') {
          if (fileName == 'index.html') {
            request.response.write(
              utf8
                  .decode(bytes)
                  .replaceFirst('<base href="/">', '<base href="/$token/">'),
            );
          } else {
            request.response.add(bytes);
          }
        }
      } catch (_) {
        request.response.statusCode = 500;
      } finally {
        await request.response.close().catchError((Object _) {});
      }
    });
    return _preview!;
  }

  @override
  Future<void> openPreview(Uri uri) async {
    if (_server == null || uri != _preview || !Platform.isMacOS) {
      throw StateError('Start a current local preview first.');
    }
    final result = await Process.run('/usr/bin/open', [
      uri.toString(),
    ]).timeout(const Duration(seconds: 10));
    if (result.exitCode != 0) throw StateError('Browser could not be opened.');
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _activeProcess?.kill(ProcessSignal.sigterm);
    await stopPreview();
  }

  @override
  Future<void> stopPreview() async {
    final server = _server;
    _server = null;
    _preview = null;
    await server?.close(force: true);
  }
}

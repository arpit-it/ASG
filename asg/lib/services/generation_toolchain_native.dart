// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/generation_toolchain.dart';

/// Never executes configured files, follows no relative PATH entries and caps
/// lookup work. Metadata operations can finish after the observation deadline.
Future<GenerationToolchain> inspectGenerationToolchain(
  String sdk,
  String python, {
  String? searchPath,
}) async {
  if (!Platform.isMacOS && !Platform.isLinux) {
    return const GenerationToolchain.unavailable();
  }
  try {
    return await _inspect(
      sdk,
      python,
      searchPath ?? Platform.environment['PATH'],
    ).timeout(const Duration(seconds: 3));
  } catch (_) {
    return const GenerationToolchain.failed();
  }
}

bool _bounded(String value) =>
    value.isNotEmpty && value.length <= 4096 && !value.contains('\u0000');

Future<String> _file(String value, {String? sdkRelativePath}) async {
  try {
    // Resolve selected executable aliases, but require a final ordinary file.
    final resolved = await File(value).resolveSymbolicLinks();
    final stat = await File(resolved).stat();
    if (stat.type != FileSystemEntityType.file) {
      return 'No regular executable file found. Check the selected path.';
    }
    if (stat.mode & 0x49 == 0) {
      return 'File has no executable permission bits. Check permissions.';
    }
    return 'Regular file with executable permission bits observed.';
  } catch (_) {
    return sdkRelativePath == null
        ? 'File unavailable. Check the selected path and permissions.'
        : 'File unavailable. Check $sdkRelativePath in the selected SDK and its permissions.';
  }
}

Future<GenerationToolchain> _inspect(
  String sdk,
  String python,
  String? searchPath,
) async {
  var flutter = 'Choose an absolute, real Flutter SDK directory.';
  var dart = flutter;
  if (_bounded(sdk) && path.isAbsolute(sdk)) {
    try {
      final canonical = await Directory(sdk).resolveSymbolicLinks();
      if (canonical == path.normalize(sdk)) {
        if (await FileSystemEntity.type(canonical) !=
            FileSystemEntityType.directory) {
          flutter = dart = 'The selected Flutter SDK path is not a directory.';
        } else {
          const flutterPath = 'bin/flutter';
          const dartPath = 'bin/cache/dart-sdk/bin/dart';
          flutter = await _file(
            path.join(canonical, flutterPath),
            sdkRelativePath: flutterPath,
          );
          dart = await _file(
            path.join(canonical, dartPath),
            sdkRelativePath: dartPath,
          );
        }
      }
    } catch (_) {
      flutter = dart =
          'SDK directory unavailable. Check the path and permissions.';
    }
  }
  var pythonResult = 'Choose an absolute Python executable or a command name.';
  if (_bounded(python)) {
    if (path.isAbsolute(python)) {
      pythonResult = await _file(python);
    } else if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(python)) {
      pythonResult = await _inspectPythonPath(python, searchPath);
    }
  }
  return GenerationToolchain(flutter, dart, pythonResult);
}

Future<String> _inspectPythonPath(String python, String? searchPath) async {
  const guidance = 'Choose an absolute Python executable.';
  if (searchPath == null || searchPath.isEmpty) {
    return 'PATH is unavailable or empty. $guidance';
  }
  if (searchPath.length > 65536) {
    return 'PATH exceeds the inspection limit of 65,536 characters. $guidance';
  }
  var checkedFolder = false;
  // Empty or relative entries count toward the limit without being searched.
  for (final folder in searchPath.split(':').take(64)) {
    if (!_bounded(folder) || !path.isAbsolute(folder)) continue;
    checkedFolder = true;
    final candidate = path.join(folder, python);
    if (await FileSystemEntity.type(candidate) !=
        FileSystemEntityType.notFound) {
      // Report the first observed candidate, even if it is unusable.
      return _file(candidate);
    }
  }
  if (!checkedFolder) {
    return 'The first 64 PATH entries contain no eligible absolute directory '
        'paths. $guidance';
  }
  return 'Command not found in the eligible directories among the first 64 '
      'PATH entries. $guidance';
}

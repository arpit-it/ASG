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

Future<String> _file(String value) async {
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
    return 'File unavailable. Check the selected path and permissions.';
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
        flutter = await _file(path.join(canonical, 'bin', 'flutter'));
        dart = await _file(
          path.join(canonical, 'bin', 'cache', 'dart-sdk', 'bin', 'dart'),
        );
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
      pythonResult = 'Command not found in the first 64 absolute PATH entries. Choose an absolute Python executable.';
      // Bound both environment parsing and filesystem work; empty/relative
      // entries never cause a search in the working directory.
      if (searchPath != null && searchPath.length <= 65536) {
        for (final folder in searchPath.split(':').take(64)) {
          if (!_bounded(folder) || !path.isAbsolute(folder)) continue;
          final candidate = path.join(folder, python);
          if (await FileSystemEntity.type(candidate) !=
              FileSystemEntityType.notFound) {
            // First matching entry is authoritative; do not hide a broken one
            // by reporting a later executable that a launch may not use.
            pythonResult = await _file(candidate);
            break;
          }
        }
      }
    }
  }
  return GenerationToolchain(flutter, dart, pythonResult);
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../models/project_inspection.dart';

/// Bounded metadata inspection without commands or filesystem writes.
class ProjectInspector {
  static const maxManifestBytes = 64 * 1024;
  Future<ProjectInspection> inspect(String path) async {
    if (path.trim().isEmpty || !p.isAbsolute(path)) {
      throw const FormatException('Choose an absolute Flutter project folder.');
    }
    final root = p.normalize(path);
    var ancestor = root;
    while (true) {
      if (await FileSystemEntity.type(ancestor, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException(
          'Project folder must contain no linked ancestors.',
        );
      }
      final parent = p.dirname(ancestor);
      if (parent == ancestor) break;
      ancestor = parent;
    }
    Future<void> requireType(String relative, FileSystemEntityType type) async {
      if (await FileSystemEntity.type(
            p.join(root, relative),
            followLinks: false,
          ) !=
          type) {
        throw FormatException('Missing or linked project entry: $relative');
      }
    }

    await requireType('pubspec.yaml', FileSystemEntityType.file);
    await requireType('lib', FileSystemEntityType.directory);
    await requireType('lib/main.dart', FileSystemEntityType.file);
    final file = await File(p.join(root, 'pubspec.yaml')).open();
    late final String manifest;
    try {
      final bytes = await file.read(maxManifestBytes + 1);
      if (bytes.length > maxManifestBytes) {
        throw const FormatException('Project manifest exceeds 64 KiB.');
      }
      manifest = utf8.decode(bytes);
    } finally {
      await file.close();
    }
    final data = loadYaml(manifest);
    if (data is! YamlMap ||
        data['name'] is! String ||
        !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(data['name'] as String)) {
      throw const FormatException('Manifest requires a valid package name.');
    }
    final dependencies = data['dependencies'];
    final flutter = dependencies is YamlMap ? dependencies['flutter'] : null;
    if (flutter is! YamlMap || flutter['sdk'] != 'flutter') {
      throw const FormatException(
        'Manifest must declare the Flutter SDK dependency.',
      );
    }
    final environment = data['environment'];
    final sdk = environment is YamlMap ? environment['sdk'] : null;
    if (sdk is! String || sdk.trim().isEmpty) {
      throw const FormatException(
        'Manifest must declare a Dart SDK constraint.',
      );
    }
    final runners = <String>[];
    for (final runner in [
      'android',
      'ios',
      'web',
      'macos',
      'windows',
      'linux',
    ]) {
      final type = await FileSystemEntity.type(
        p.join(root, runner),
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory) runners.add(runner);
      if (type == FileSystemEntityType.link) {
        throw FormatException(
          'Linked platform directory is unsupported: $runner',
        );
      }
    }
    return ProjectInspection(
      root: root,
      packageName: data['name'] as String,
      dartSdk: sdk,
      runners: runners,
    );
  }
}

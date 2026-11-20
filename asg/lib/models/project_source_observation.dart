// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'structured_proposal_json.dart';

enum ProjectSourceStatus {
  observed,
  invalid,
  unsupported,
  changed,
  unavailable,
}

/// Exact captured source data and attribution, never execution authority.
final class ProjectSourceFile {
  ProjectSourceFile._(this.path, List<int> bytes, this.digest, this.text)
    : bytes = List<int>.unmodifiable(bytes);
  final String path, digest, text;
  final List<int> bytes;
  int get byteLength => bytes.length;
}

final class ProjectSourceObservation {
  ProjectSourceObservation._(
    this.status,
    this.reason,
    List<String> paths,
    List<ProjectSourceFile> files,
  ) : selectedPaths = List<String>.unmodifiable(paths),
      files = List<ProjectSourceFile>.unmodifiable(files);
  final ProjectSourceStatus status;
  final String? reason;
  final List<String> selectedPaths;
  final List<ProjectSourceFile> files;
  bool get sourceVerified => false;
  static const responseLimit = 128 * 1024,
      fileLimit = 32 * 1024,
      aggregateLimit = 64 * 1024;
  static const _keys = {
    'version',
    'scope',
    'status',
    'reason',
    'selected_paths',
    'files',
    'source_verified',
  };
  static const _fileKeys = {'path', 'byte_length', 'sha256', 'content_base64'};
  static const _reasons = {
    'invalid_selection',
    'invalid_request',
    'invalid_root',
    'root_path_subset',
    'posix_nofollow_unavailable',
    'directory_indirection',
    'unsafe_source',
    'source_too_large',
    'sources_too_large',
    'source_missing',
    'source_encoding',
    'source_unavailable',
    'source_changed',
    'duplicate_source_identity',
    'directory_changed',
    'missing_source_appeared',
    'output_limit',
  };

  /// Mirrors the literal ASCII subset of the versioned source helper.
  static bool validSelection(List<String> paths) {
    if (paths.isEmpty || paths.length > 4) return false;
    final component = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$');
    for (final value in paths) {
      if (value.isEmpty ||
          value.length > 512 ||
          value.codeUnits.any((c) => c < 32 || c > 126)) {
        return false;
      }
      final parts = value.split('/');
      if (parts.length < 2 ||
          parts.length > 16 ||
          !['lib', 'test'].contains(parts.first) ||
          !parts.last.endsWith('.dart') ||
          parts.any((p) => p == '.' || p == '..' || !component.hasMatch(p))) {
        return false;
      }
    }
    return paths.map((p) => p.toLowerCase()).toSet().length == paths.length;
  }

  factory ProjectSourceObservation.unavailable() => ProjectSourceObservation._(
    ProjectSourceStatus.unavailable,
    'host_unavailable',
    [],
    [],
  );
  factory ProjectSourceObservation.fromJson(String raw) {
    try {
      if (utf8.encode(raw).length > responseLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value.length != _keys.length ||
          !value.keys.toSet().containsAll(_keys) ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['scope'] != 'project-source-files' ||
          value['source_verified'] != false) {
        throw const FormatException();
      }
      final status = ProjectSourceStatus.values.singleWhere(
        (s) => s.name == value['status'],
      );
      final rawPaths = value['selected_paths'], rawFiles = value['files'];
      if (rawPaths is! List ||
          rawPaths.any((p) => p is! String) ||
          rawFiles is! List) {
        throw const FormatException();
      }
      final paths = rawPaths.cast<String>();
      if (paths.isNotEmpty && !validSelection(paths)) {
        throw const FormatException();
      }
      if (status != ProjectSourceStatus.observed) {
        if (!_reasons.contains(value['reason']) || rawFiles.isNotEmpty) {
          throw const FormatException();
        }
        return ProjectSourceObservation._(
          status,
          value['reason'] as String,
          paths,
          [],
        );
      }
      if (!validSelection(paths) ||
          value['reason'] != null ||
          rawFiles.length != paths.length) {
        throw const FormatException();
      }
      final files = <ProjectSourceFile>[];
      var total = 0;
      for (var i = 0; i < paths.length; i++) {
        final item = rawFiles[i];
        if (item is! Map<String, dynamic> ||
            item.length != _fileKeys.length ||
            !item.keys.toSet().containsAll(_fileKeys) ||
            item['path'] != paths[i] ||
            item['byte_length'] is! int ||
            item['sha256'] is! String ||
            item['content_base64'] is! String) {
          throw const FormatException();
        }
        final length = item['byte_length'] as int;
        final encoded = item['content_base64'] as String,
            digest = item['sha256'] as String;
        if (length < 0 ||
            length > fileLimit ||
            encoded.length > 43692 ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
          throw const FormatException();
        }
        final bytes = base64Decode(encoded);
        if (bytes.length != length ||
            base64Encode(bytes) != encoded ||
            sha256.convert(bytes).toString() != digest) {
          throw const FormatException();
        }
        total += bytes.length;
        if (total > aggregateLimit) throw const FormatException();
        var text = utf8.decode(bytes, allowMalformed: false);
        // Dart strips the BOM; retain it in the captured plain text.
        if (bytes.length >= 3 &&
            bytes[0] == 239 &&
            bytes[1] == 187 &&
            bytes[2] == 191) {
          text = '\ufeff$text';
        }
        if (text.contains('\u0000')) throw const FormatException();
        files.add(ProjectSourceFile._(paths[i], bytes, digest, text));
      }
      return ProjectSourceObservation._(status, null, paths, files);
    } catch (_) {
      throw const FormatException('Source file response is invalid.');
    }
  }
}

/// Frozen selection and transport inputs; grants no read authority.
final class ProjectSourceReadRequest {
  ProjectSourceReadRequest({
    required this.root,
    required this.python,
    required List<String> selectedPaths,
  }) : selectedPaths = List<String>.unmodifiable(selectedPaths) {
    if (!ProjectSourceObservation.validSelection(this.selectedPaths)) {
      throw const FormatException('Select 1–4 supported Dart source paths.');
    }
  }
  final String root, python;
  final List<String> selectedPaths;
}

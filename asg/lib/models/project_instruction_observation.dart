// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'structured_proposal_json.dart';

enum ProjectInstructionStatus {
  observed,
  invalid,
  unsupported,
  changed,
  unavailable,
}

/// Exact captured data and attribution, never executable instructions.
final class ProjectInstructionDocument {
  ProjectInstructionDocument._(
    this.path,
    List<int> bytes,
    this.digest,
    this.text,
  ) : bytes = List<int>.unmodifiable(bytes);
  final String path, digest, text;
  final List<int> bytes;
  int get byteLength => bytes.length;
}

final class ProjectInstructionObservation {
  ProjectInstructionObservation._(
    this.status,
    this.reason,
    List<String> paths,
    List<ProjectInstructionDocument> documents,
  ) : selectedPaths = List<String>.unmodifiable(paths),
      documents = List<ProjectInstructionDocument>.unmodifiable(documents);
  final ProjectInstructionStatus status;
  final String? reason;
  final List<String> selectedPaths;
  final List<ProjectInstructionDocument> documents;
  bool get sourceVerified => false;
  static const responseLimit = 128 * 1024,
      documentLimit = 32 * 1024,
      aggregateLimit = 64 * 1024;
  static const allowedPaths = ['AGENTS.md', 'README.md'];
  static const _keys = {
    'version',
    'scope',
    'status',
    'reason',
    'selected_paths',
    'documents',
    'source_verified',
  };
  static const _documentKeys = {
    'path',
    'byte_length',
    'sha256',
    'content_base64',
  };
  static const _reasons = {
    'invalid_selection',
    'invalid_request',
    'invalid_root',
    'root_path_subset',
    'posix_nofollow_unavailable',
    'directory_indirection',
    'unsafe_document',
    'document_too_large',
    'documents_too_large',
    'document_missing',
    'document_encoding',
    'document_unavailable',
    'document_changed',
    'directory_changed',
    'missing_document_appeared',
    'output_limit',
  };
  static bool validSelection(List<String> paths) {
    if (paths.isEmpty || paths.length > allowedPaths.length) return false;
    var previous = -1;
    for (final path in paths) {
      final index = allowedPaths.indexOf(path);
      if (index <= previous) return false;
      previous = index;
    }
    return true;
  }

  factory ProjectInstructionObservation.unavailable() =>
      ProjectInstructionObservation._(
        ProjectInstructionStatus.unavailable,
        'host_unavailable',
        [],
        [],
      );
  factory ProjectInstructionObservation.fromJson(String raw) {
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
          value['scope'] != 'project-instruction-documents' ||
          value['source_verified'] != false) {
        throw const FormatException();
      }
      final status = ProjectInstructionStatus.values.singleWhere(
        (s) => s.name == value['status'],
      );
      final rawPaths = value['selected_paths'],
          rawDocuments = value['documents'];
      if (rawPaths is! List ||
          rawPaths.any((p) => p is! String) ||
          rawDocuments is! List) {
        throw const FormatException();
      }
      final paths = rawPaths.cast<String>();
      if (paths.isNotEmpty && !validSelection(paths)) {
        throw const FormatException();
      }
      if (status != ProjectInstructionStatus.observed) {
        if (!_reasons.contains(value['reason']) || rawDocuments.isNotEmpty) {
          throw const FormatException();
        }
        return ProjectInstructionObservation._(
          status,
          value['reason'] as String,
          paths,
          [],
        );
      }
      if (!validSelection(paths) ||
          value['reason'] != null ||
          rawDocuments.length != paths.length) {
        throw const FormatException();
      }
      final documents = <ProjectInstructionDocument>[];
      var total = 0;
      for (var i = 0; i < paths.length; i++) {
        final item = rawDocuments[i];
        if (item is! Map<String, dynamic> ||
            item.length != _documentKeys.length ||
            !item.keys.toSet().containsAll(_documentKeys) ||
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
            length > documentLimit ||
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
        documents.add(
          ProjectInstructionDocument._(paths[i], bytes, digest, text),
        );
      }
      return ProjectInstructionObservation._(status, null, paths, documents);
    } catch (_) {
      throw const FormatException('Instruction document response is invalid.');
    }
  }
}

/// Frozen selection and transport inputs; grants no read authority.
final class ProjectInstructionReadRequest {
  ProjectInstructionReadRequest({
    required this.root,
    required this.python,
    required List<String> selectedPaths,
  }) : selectedPaths = List<String>.unmodifiable(selectedPaths) {
    if (!ProjectInstructionObservation.validSelection(this.selectedPaths)) {
      throw const FormatException('Select supported instruction documents.');
    }
  }
  final String root, python;
  final List<String> selectedPaths;
}

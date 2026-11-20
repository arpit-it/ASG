// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_commit_source_observation.dart';
import 'imported_repository_context.dart';
import 'project_inspection.dart';
import 'requirements_board.dart';
import 'structured_proposal_json.dart';

/// Historical selected commit data plus app planning inputs, never current disk,
/// authenticated origin, committed toolchain metadata or a sharing/write grant.
final class ImportedCommitContext implements ImportedRepositoryContext {
  ImportedCommitContext._(
    this.recordJson,
    this.digest,
    this._metadataJson,
    this._requirementsJson,
    this.commit,
    this.tree,
    this.manifestDigest,
    this.manifestFiles,
    List<ImportedCommitSourceFile> files,
  ) : files = List.unmodifiable(files);

  static const byteLimit = 128 * 1024;
  @override
  final String recordJson;
  @override
  final String digest;
  final String _metadataJson, _requirementsJson;
  final String commit, tree, manifestDigest;
  final int manifestFiles;
  final List<ImportedCommitSourceFile> files;
  @override
  bool get sourceVerified => false;
  @override
  bool get includesSource => true;
  String get workingTree => 'unknown';
  String get conflict => 'unknown';
  @override
  List<({String path, int byteLength, String digest, String text})>
  get capturedFiles => List.unmodifiable([
    for (final file in files)
      (
        path: file.source.path,
        byteLength: file.source.byteLength,
        digest: file.source.digest,
        text: file.source.text,
      ),
  ]);

  static Map<String, Object> _metadata(ProjectInspection inspection) => {
    'root': inspection.root,
    'package': inspection.packageName,
    'dartSdk': inspection.dartSdk,
    'runners': inspection.runners,
  };

  static void _unicode(Object? value, [int depth = 0]) {
    if (depth > 32) throw const FormatException();
    if (value is String) {
      for (var i = 0; i < value.length; i++) {
        final c = value.codeUnitAt(i);
        if (c >= 0xd800 && c <= 0xdbff) {
          if (++i >= value.length ||
              value.codeUnitAt(i) < 0xdc00 ||
              value.codeUnitAt(i) > 0xdfff) {
            throw const FormatException();
          }
        } else if (c >= 0xdc00 && c <= 0xdfff) {
          throw const FormatException();
        }
      }
    } else if (value is Map) {
      for (final entry in value.entries) {
        _unicode(entry.key, depth + 1);
        _unicode(entry.value, depth + 1);
      }
    } else if (value is List) {
      for (final item in value) {
        _unicode(item, depth + 1);
      }
    }
  }

  @override
  bool matchesPlanningInputs(
    ProjectInspection inspection,
    RequirementsBoard requirements,
  ) {
    try {
      requirements.validate();
      return _metadataJson == jsonEncode(_metadata(inspection)) &&
          _requirementsJson == jsonEncode(requirements.toJson());
    } catch (_) {
      return false;
    }
  }

  static ImportedCommitContext _build(
    ProjectInspection inspection,
    RequirementsBoard requirements,
    ImportedCommitSourceObservation observation,
  ) {
    if (observation.status != ImportedCommitSourceStatus.observed ||
        observation.root != inspection.root) {
      throw const FormatException();
    }
    requirements.validate();
    final metadata = _metadata(inspection), board = requirements.toJson();
    final data = {
      'version': 1,
      'scope': 'captured-imported-commit-context',
      'source_verified': false,
      'working_tree': 'unknown',
      'conflict': 'unknown',
      'metadata': metadata,
      'requirements': board,
      'commit': observation.commit,
      'tree': observation.tree,
      'manifest_sha256': observation.manifestDigest,
      'manifest_files': observation.manifestFiles,
      'selected_paths': observation.selectedPaths,
      'files': [
        for (final file in observation.files)
          {
            'path': file.source.path,
            'mode': file.mode,
            'git_blob': file.gitBlob,
            'byte_length': file.source.byteLength,
            'sha256': file.source.digest,
            'text': file.source.text,
          },
      ],
    };
    _unicode(data);
    final raw = jsonEncode(data);
    if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
      throw const FormatException();
    }
    return ImportedCommitContext._(
      raw,
      sha256.convert(utf8.encode(raw)).toString(),
      jsonEncode(metadata),
      jsonEncode(board),
      observation.commit!,
      observation.tree!,
      observation.manifestDigest!,
      observation.manifestFiles!,
      observation.files,
    );
  }

  /// The caller must separately establish consent, native read ownership and
  /// unchanged app inputs. This pure constructor cannot establish those facts.
  factory ImportedCommitContext.capture({
    required ProjectInspection inspection,
    required RequirementsBoard requirements,
    required ImportedCommitReadRequest request,
    required ImportedCommitSourceObservation observation,
  }) {
    try {
      if (!observation.matchesRequest(request)) throw const FormatException();
      return _build(inspection, requirements, observation);
    } catch (_) {
      throw const FormatException('Captured commit context is invalid.');
    }
  }

  /// Restores canonical supplied history only, without rereading or approving it.
  factory ImportedCommitContext.restore(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final data = jsonDecode(raw);
      _unicode(data);
      const keys = {
        'version',
        'scope',
        'source_verified',
        'working_tree',
        'conflict',
        'metadata',
        'requirements',
        'commit',
        'tree',
        'manifest_sha256',
        'manifest_files',
        'selected_paths',
        'files',
      };
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'captured-imported-commit-context' ||
          data['source_verified'] != false ||
          data['working_tree'] != 'unknown' ||
          data['conflict'] != 'unknown') {
        throw const FormatException();
      }
      final metadata = data['metadata'] as Map<String, dynamic>;
      const metadataKeys = {'root', 'package', 'dartSdk', 'runners'};
      if (metadata.length != metadataKeys.length ||
          !metadata.keys.toSet().containsAll(metadataKeys) ||
          metadata['root'] is! String ||
          metadata['package'] is! String ||
          metadata['dartSdk'] is! String ||
          metadata['runners'] is! List ||
          (metadata['runners'] as List).any((r) => r is! String)) {
        throw const FormatException();
      }
      final inspection = ProjectInspection(
        root: metadata['root'] as String,
        packageName: metadata['package'] as String,
        dartSdk: metadata['dartSdk'] as String,
        runners: (metadata['runners'] as List).cast<String>(),
      );
      final boardData = data['requirements'] as Map<String, dynamic>;
      final empty = RequirementsBoard();
      final board = jsonEncode(boardData) == jsonEncode(empty.toJson())
          ? empty
          : RequirementsBoard.fromJson(boardData);
      final files = data['files'] as List;
      const fileKeys = {
        'path',
        'mode',
        'git_blob',
        'byte_length',
        'sha256',
        'text',
      };
      for (final file in files) {
        if (file is! Map<String, dynamic> ||
            file.length != fileKeys.length ||
            !file.keys.toSet().containsAll(fileKeys) ||
            file['text'] is! String) {
          throw const FormatException();
        }
      }
      // Reuse strict mode/readset/hash/blob/UTF8/BOM/byte validation. Restoring
      // history needs no interpreter or fabricated live-read request identity.
      final observation = ImportedCommitSourceObservation.fromJson(
        jsonEncode({
          'version': 1,
          'scope': 'imported-commit-source',
          'status': 'observed',
          'reason': null,
          'root': inspection.root,
          'commit': data['commit'],
          'selected_paths': data['selected_paths'],
          'tree': data['tree'],
          'manifest_sha256': data['manifest_sha256'],
          'manifest_files': data['manifest_files'],
          'source_verified': false,
          'working_tree': 'unknown',
          'conflict': 'unknown',
          'files': [
            for (final f in files)
              {
                for (final key in [
                  'path',
                  'mode',
                  'git_blob',
                  'byte_length',
                  'sha256',
                ])
                  key: f[key],
                'content_base64': base64Encode(
                  utf8.encode(f['text'] as String),
                ),
              },
          ],
        }),
      );
      final restored = _build(inspection, board, observation);
      if (restored.recordJson != raw) throw const FormatException();
      return restored;
    } catch (_) {
      throw const FormatException('Saved captured commit context is invalid.');
    }
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'project_source_observation.dart';
import 'structured_proposal_json.dart';

bool _oid(String value) =>
    value.length == 40 &&
    value.codeUnits.every(
      (c) => (c >= 48 && c <= 57) || (c >= 97 && c <= 102),
    ) &&
    value.codeUnits.any((c) => c != 48);
bool _sha256(String value) =>
    value.length == 64 &&
    value.codeUnits.every((c) => (c >= 48 && c <= 57) || (c >= 97 && c <= 102));
bool _absolute(String value) =>
    value.length <= 4096 &&
    utf8.encode(value).length <= 4096 &&
    utf8.decode(utf8.encode(value)) == value &&
    value != '/' &&
    !value.startsWith('//') &&
    path.posix.isAbsolute(value) &&
    path.posix.normalize(value) == value &&
    value.split('/').length <= 129 &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

/// Frozen data request. Native code must separately validate physical paths and
/// bind consent, current app inputs and owned helper process/cleanup.
final class ImportedCommitReadRequest {
  ImportedCommitReadRequest._(
    this.root,
    this.python,
    this.commit,
    List<String> paths,
  ) : selectedPaths = List.unmodifiable(paths);
  final String root, python, commit;
  final List<String> selectedPaths;
  static bool validCommit(String value) => _oid(value);
  factory ImportedCommitReadRequest({
    required String root,
    required String python,
    required String commit,
    required List<String> selectedPaths,
  }) {
    try {
      if (!_absolute(root) ||
          !_absolute(python) ||
          !_oid(commit) ||
          !ProjectSourceObservation.validSelection(selectedPaths) ||
          path.posix.equals(root.toLowerCase(), python.toLowerCase()) ||
          path.posix.isWithin(root.toLowerCase(), python.toLowerCase())) {
        throw const FormatException();
      }
      return ImportedCommitReadRequest._(root, python, commit, selectedPaths);
    } catch (_) {
      throw const FormatException('Invalid immutable commit read request.');
    }
  }
}

enum ImportedCommitSourceStatus { observed, refused }

/// Mode is observed tree metadata, never permission to execute the source.
final class ImportedCommitSourceFile {
  ImportedCommitSourceFile._(this.source, this.gitBlob, this.mode);
  final ProjectSourceFile source;
  final String gitBlob, mode;
}

/// Supplied helper data only. A successful decode does not prove that a native
/// read ran, authenticate repository origin, certify working state or grant access.
final class ImportedCommitSourceObservation {
  ImportedCommitSourceObservation._(
    this.status,
    this.reason,
    this.root,
    this.commit,
    List<String> paths,
    this.tree,
    this.manifestDigest,
    this.manifestFiles,
    List<ImportedCommitSourceFile> files,
  ) : selectedPaths = List.unmodifiable(paths),
      files = List.unmodifiable(files);
  final ImportedCommitSourceStatus status;
  final String? reason, root, commit, tree, manifestDigest;
  final int? manifestFiles;
  final List<String> selectedPaths;
  final List<ImportedCommitSourceFile> files;
  bool get sourceVerified => false;
  String get workingTree => 'unknown';
  String get conflict => 'unknown';
  static const responseLimit = ProjectSourceObservation.responseLimit;
  static const _keys = {
    'version',
    'scope',
    'status',
    'reason',
    'root',
    'commit',
    'selected_paths',
    'tree',
    'manifest_sha256',
    'manifest_files',
    'source_verified',
    'working_tree',
    'conflict',
    'files',
  };
  static const _fileKeys = {
    'path',
    'git_blob',
    'mode',
    'byte_length',
    'sha256',
    'content_base64',
  };
  static const _reasons = {
    'unsupported_host',
    'unsupported_layout',
    'unsupported_configuration',
    'repository_changed',
    'stopped',
    'deadline',
    'object_limit',
    'object_unavailable',
    'cleanup_uncertain',
    'tree_limit',
    'selected_path_missing',
    'sources_limit',
    'response_limit',
    'invalid_object_or_request',
    'repository_unavailable',
    'invalid_request',
  };

  bool matchesRequest(ImportedCommitReadRequest request) =>
      root == request.root &&
      commit == request.commit &&
      selectedPaths.length == request.selectedPaths.length &&
      List.generate(
        selectedPaths.length,
        (i) => i,
      ).every((i) => selectedPaths[i] == request.selectedPaths[i]);

  factory ImportedCommitSourceObservation.fromJson(String raw) {
    try {
      if (raw.length > ProjectSourceObservation.responseLimit ||
          utf8.encode(raw).length > ProjectSourceObservation.responseLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value.length != _keys.length ||
          !value.keys.toSet().containsAll(_keys) ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['scope'] != 'imported-commit-source' ||
          value['source_verified'] != false ||
          value['working_tree'] != 'unknown' ||
          value['conflict'] != 'unknown') {
        throw const FormatException();
      }
      final status = ImportedCommitSourceStatus.values.singleWhere(
        (s) => s.name == value['status'],
      );
      final String? root = value['root'], commit = value['commit'];
      final rawPaths = value['selected_paths'], rawFiles = value['files'];
      if (rawPaths is! List ||
          rawPaths.any((p) => p is! String) ||
          rawFiles is! List) {
        throw const FormatException();
      }
      final paths = rawPaths.cast<String>();
      final attributed = root != null && commit != null && paths.isNotEmpty;
      if (attributed) {
        if (!_absolute(root) ||
            !_oid(commit) ||
            !ProjectSourceObservation.validSelection(paths)) {
          throw const FormatException();
        }
      } else if (root != null || commit != null || paths.isNotEmpty) {
        throw const FormatException();
      }
      if (status == ImportedCommitSourceStatus.refused) {
        if (!_reasons.contains(value['reason']) ||
            rawFiles.isNotEmpty ||
            value['tree'] != null ||
            value['manifest_sha256'] != null ||
            value['manifest_files'] != null) {
          throw const FormatException();
        }
        return ImportedCommitSourceObservation._(
          status,
          value['reason'] as String,
          root,
          commit,
          paths,
          null,
          null,
          null,
          [],
        );
      }
      final tree = value['tree'],
          manifest = value['manifest_sha256'],
          count = value['manifest_files'];
      if (!attributed ||
          value['reason'] != null ||
          tree is! String ||
          !_oid(tree) ||
          manifest is! String ||
          !_sha256(manifest) ||
          count is! int ||
          count < paths.length ||
          count > 2048 ||
          rawFiles.length != paths.length) {
        throw const FormatException();
      }
      for (final file in rawFiles) {
        if (file is! Map<String, dynamic> ||
            file.length != _fileKeys.length ||
            !file.keys.toSet().containsAll(_fileKeys) ||
            file['git_blob'] is! String ||
            !_oid(file['git_blob'] as String) ||
            !['100644', '100755'].contains(file['mode'])) {
          throw const FormatException();
        }
      }
      final supplied = ProjectSourceObservation.fromJson(
        jsonEncode({
          'version': 1,
          'scope': 'project-source-files',
          'status': 'observed',
          'reason': null,
          'selected_paths': paths,
          'source_verified': false,
          'files': [
            for (final f in rawFiles)
              {
                for (final key in [
                  'path',
                  'byte_length',
                  'sha256',
                  'content_base64',
                ])
                  key: f[key],
              },
          ],
        }),
      );
      final files = <ImportedCommitSourceFile>[];
      for (var i = 0; i < supplied.files.length; i++) {
        final source = supplied.files[i],
            file = rawFiles[i] as Map<String, dynamic>;
        final blob = sha1.convert([
          ...utf8.encode('blob ${source.byteLength}\u0000'),
          ...source.bytes,
        ]).toString();
        if (blob != file['git_blob']) throw const FormatException();
        files.add(
          ImportedCommitSourceFile._(source, blob, file['mode'] as String),
        );
      }
      return ImportedCommitSourceObservation._(
        status,
        null,
        root,
        commit,
        paths,
        tree,
        manifest,
        count,
        files,
      );
    } catch (_) {
      throw const FormatException(
        'Invalid immutable commit source observation.',
      );
    }
  }
}

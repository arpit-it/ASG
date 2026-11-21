// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_index_observation.dart';
import 'project_source_observation.dart';
import 'structured_proposal_json.dart';

bool _hex(Object? value, int length) =>
    value is String && RegExp('^[a-f0-9]{$length}\$').hasMatch(value);

Map<String, dynamic> _object(String raw, int limit, Set<String> keys) {
  if (raw.length > limit || utf8.encode(raw).length > limit) {
    throw const FormatException();
  }
  rejectDuplicateJsonMembers(raw);
  final d = jsonDecode(raw);
  if (d is! Map<String, dynamic> ||
      d.length != keys.length ||
      !d.keys.toSet().containsAll(keys)) {
    throw const FormatException();
  }
  return d;
}

final class ImportedWorkfileSelection {
  const ImportedWorkfileSelection._(this.path, this.mode, this.oid);
  final String path, mode, oid;
}

/// One-use read intent, bound to an observed index rather than Git status.
final class ImportedWorkfileRequest {
  ImportedWorkfileRequest._(
    Map<String, dynamic> d,
    List<ImportedWorkfileSelection> files,
  ) : root = d['root'] as String,
      python = d['python'] as String,
      comparisonId = d['comparison_id'] as String,
      indexRequestDigest = d['index_request_sha256'] as String,
      indexObservationDigest = d['index_observation_sha256'] as String,
      indexHash = d['index_sha256'] as String,
      indexByteLength = d['index_byte_length'] as int,
      files = List.unmodifiable(files),
      requestJson = jsonEncode(d) {
    digest = sha256.convert(utf8.encode(requestJson)).toString();
  }
  static const byteLimit = 16 * 1024;
  static const _keys = {
    'version',
    'scope',
    'root',
    'python',
    'comparison_id',
    'index_request_sha256',
    'index_observation_sha256',
    'index_sha256',
    'index_byte_length',
    'selected_files',
  };
  final String root, python, comparisonId, indexRequestDigest;
  final String indexObservationDigest, indexHash, requestJson;
  late final String digest;
  final int indexByteLength;
  final List<ImportedWorkfileSelection> files;
  bool get authorizesCommit => false;
  bool get authorizesMutation => false;
  bool get gitStateVerified => false;

  factory ImportedWorkfileRequest.create({
    required ImportedIndexReadRequest indexRequest,
    required ImportedIndexObservation indexObservation,
    required List<String> paths,
    required String comparisonId,
  }) {
    final request = ImportedIndexReadRequest.restore(indexRequest.requestJson);
    final observation = ImportedIndexObservation.fromJson(
      indexObservation.recordJson,
      request: request,
    );
    if (!observation.observed ||
        !ProjectSourceObservation.validSelection(paths)) {
      throw const FormatException(
        'A matching index read and explicit selection are required.',
      );
    }
    final sorted = List<String>.of(paths)..sort();
    if (sorted.any(
      (name) => !observation.entries.any((entry) => entry.path == name),
    )) {
      throw const FormatException(
        'Every selected file must be declared by the reviewed index.',
      );
    }
    final entries = [
      for (final name in sorted)
        observation.entries.singleWhere((entry) => entry.path == name),
    ];
    return ImportedWorkfileRequest.restore(
      jsonEncode({
        'version': 1,
        'scope': 'imported-workfile-comparison-request',
        'root': request.root,
        'python': request.python,
        'comparison_id': comparisonId,
        'index_request_sha256': request.digest,
        'index_observation_sha256': sha256
            .convert(utf8.encode(observation.recordJson))
            .toString(),
        'index_sha256': observation.indexHash,
        'index_byte_length': observation.indexByteLength,
        'selected_files': [
          for (final entry in entries)
            {'path': entry.path, 'mode': entry.mode, 'oid': entry.oid},
        ],
      }),
    );
  }

  factory ImportedWorkfileRequest.restore(String raw) {
    try {
      final d = _object(raw, byteLimit, _keys);
      if (d['version'] is! int ||
          d['version'] != 1 ||
          d['scope'] != 'imported-workfile-comparison-request' ||
          d['root'] is! String ||
          d['python'] is! String ||
          d['comparison_id'] is! String ||
          ![
            'index_request_sha256',
            'index_observation_sha256',
            'index_sha256',
          ].every((k) => _hex(d[k], 64)) ||
          d['index_byte_length'] is! int ||
          d['index_byte_length'] < 32 ||
          d['index_byte_length'] > ImportedIndexObservation.indexLimit ||
          d['selected_files'] is! List) {
        throw const FormatException();
      }
      // Reuse the exact scalar path, external-runtime and nonce boundary.
      ImportedIndexReadRequest(
        root: d['root'],
        python: d['python'],
        readId: d['comparison_id'],
      );
      final items = d['selected_files'] as List;
      if (items.isEmpty || items.length > 4) throw const FormatException();
      final files = <ImportedWorkfileSelection>[];
      String? previous;
      var minimum = 32;
      for (final item in items) {
        if (item is! Map<String, dynamic> ||
            item.length != 3 ||
            !item.keys.toSet().containsAll(['path', 'mode', 'oid']) ||
            item['path'] is! String ||
            !['100644', '100755'].contains(item['mode']) ||
            !_hex(item['oid'], 40) ||
            item['oid'] == '0' * 40) {
          throw const FormatException();
        }
        final name = item['path'] as String;
        if (previous != null && name.compareTo(previous) <= 0) {
          throw const FormatException();
        }
        files.add(
          ImportedWorkfileSelection._(
            name,
            item['mode'] as String,
            item['oid'] as String,
          ),
        );
        minimum += ((62 + name.length + 1 + 7) ~/ 8) * 8;
        previous = name;
      }
      if (!ProjectSourceObservation.validSelection(
            files.map((f) => f.path).toList(),
          ) ||
          minimum > d['index_byte_length']) {
        throw const FormatException();
      }
      return ImportedWorkfileRequest._({for (final k in _keys) k: d[k]}, files);
    } catch (_) {
      throw const FormatException(
        'Invalid selected working-file comparison request.',
      );
    }
  }
  bool matches(ImportedWorkfileRequest other) =>
      requestJson == other.requestJson;
}

final class ImportedWorkfileResult {
  const ImportedWorkfileResult._(
    this.path,
    this.byteLength,
    this.hash,
    this.rawBlob,
    this.executable,
    this.rawBlobMatches,
    this.executableMatches,
  );
  final String path, hash, rawBlob;
  final int byteLength;
  final bool executable, rawBlobMatches, executableMatches;
}

enum ImportedWorkfileStatus { observed, refused, stopped }

/// Dated literal comparisons only. Filters and whole repository state stay unknown.
final class ImportedWorkfileObservation {
  ImportedWorkfileObservation._(
    this.status,
    this.requestDigest,
    this.reason,
    this.indexHash,
    List<ImportedWorkfileResult> files,
    this.recordedAt,
    this.recordJson,
  ) : files = List.unmodifiable(files);
  static const responseLimit = 32 * 1024,
      fileLimit = 32 * 1024,
      aggregateLimit = 64 * 1024;
  final ImportedWorkfileStatus status;
  final String requestDigest, recordJson;
  final String? reason, indexHash;
  final List<ImportedWorkfileResult> files;
  final DateTime recordedAt;
  bool get observed => status == ImportedWorkfileStatus.observed;
  bool get authorizesCommit => false;
  bool get authorizesMutation => false;
  bool get gitStateVerified => false;
  String get filters => 'unknown';
  String get workingTree => 'unknown';
  String get headMembership => 'unknown';
  static const _keys = {
    'version',
    'scope',
    'request_sha256',
    'comparison_id',
    'root',
    'index_sha256',
    'status',
    'reason',
    'files',
    'git_state_verified',
    'head_membership',
    'filters',
    'working_tree',
    'commit_authorized',
    'mutation_authorized',
    'recorded_at',
  };
  factory ImportedWorkfileObservation.fromJson(
    String raw, {
    required ImportedWorkfileRequest request,
  }) {
    try {
      final d = _object(raw, responseLimit, _keys);
      if (d['version'] is! int ||
          d['version'] != 1 ||
          d['scope'] != 'imported-workfile-comparison' ||
          d['request_sha256'] != request.digest ||
          d['comparison_id'] != request.comparisonId ||
          d['root'] != request.root ||
          d['git_state_verified'] != false ||
          d['head_membership'] != 'unknown' ||
          d['filters'] != 'unknown' ||
          d['working_tree'] != 'unknown' ||
          d['commit_authorized'] != false ||
          d['mutation_authorized'] != false ||
          d['files'] is! List ||
          d['recorded_at'] is! String) {
        throw const FormatException();
      }
      final status = ImportedWorkfileStatus.values.singleWhere(
        (s) => s.name == d['status'],
      );
      final items = d['files'] as List;
      final files = <ImportedWorkfileResult>[];
      if (status == ImportedWorkfileStatus.observed) {
        if (d['reason'] != null ||
            d['index_sha256'] != request.indexHash ||
            items.length != request.files.length) {
          throw const FormatException();
        }
        var total = 0;
        for (var i = 0; i < items.length; i++) {
          final item = items[i], selected = request.files[i];
          if (item is! Map<String, dynamic> ||
              item.length != 7 ||
              !item.keys.toSet().containsAll([
                'path',
                'byte_length',
                'sha256',
                'raw_blob',
                'executable',
                'raw_blob_matches',
                'executable_matches',
              ]) ||
              item['path'] != selected.path ||
              item['byte_length'] is! int ||
              item['byte_length'] < 0 ||
              item['byte_length'] > fileLimit ||
              !_hex(item['sha256'], 64) ||
              !_hex(item['raw_blob'], 40) ||
              item['executable'] is! bool ||
              item['raw_blob_matches'] is! bool ||
              item['executable_matches'] is! bool ||
              item['raw_blob_matches'] != (item['raw_blob'] == selected.oid) ||
              item['executable_matches'] !=
                  (item['executable'] == (selected.mode == '100755'))) {
            throw const FormatException();
          }
          total += item['byte_length'] as int;
          if (total > aggregateLimit) throw const FormatException();
          files.add(
            ImportedWorkfileResult._(
              selected.path,
              item['byte_length'] as int,
              item['sha256'] as String,
              item['raw_blob'] as String,
              item['executable'] as bool,
              item['raw_blob_matches'] as bool,
              item['executable_matches'] as bool,
            ),
          );
        }
      } else {
        const reasons = {
          'unsupported_index',
          'index_changed',
          'unindexed',
          'source_missing',
          'unsafe_source',
          'changed',
          'bounds',
          'unavailable',
          'invalid_request',
          'stopped',
        };
        if (items.isNotEmpty ||
            d['index_sha256'] != null ||
            !reasons.contains(d['reason']) ||
            ((status == ImportedWorkfileStatus.stopped) !=
                (d['reason'] == 'stopped'))) {
          throw const FormatException();
        }
      }
      final at = DateTime.parse(d['recorded_at'] as String).toUtc();
      if (at.toIso8601String() != d['recorded_at']) {
        throw const FormatException();
      }
      return ImportedWorkfileObservation._(
        status,
        request.digest,
        d['reason'] as String?,
        d['index_sha256'] as String?,
        files,
        at,
        jsonEncode({for (final k in _keys) k: d[k]}),
      );
    } catch (_) {
      throw const FormatException(
        'Invalid selected working-file comparison observation.',
      );
    }
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'git_head_observation.dart';
import 'imported_reference_acquisition.dart';
import 'imported_object_acquisition.dart';
import 'imported_index_observation.dart';
import 'imported_workfile_comparison.dart';
import 'project_source_observation.dart';
import 'structured_proposal_json.dart';

bool _label(Object? value, int size) =>
    value is String && RegExp('^[a-f0-9]{$size}\$').hasMatch(value);
bool _oid(Object? value) => _label(value, 40) && value != '0' * 40;
Map<String, dynamic> _decode(
  String raw,
  int limit,
  Set<String> keys, {
  String? extraKey,
  int? extraVersion,
}) {
  if (raw.length > limit || utf8.encode(raw).length > limit) {
    throw const FormatException();
  }
  rejectDuplicateJsonMembers(raw);
  final d = jsonDecode(raw);
  final expected = {
    ...keys,
    if (d is Map<String, dynamic> &&
        d['version'] == extraVersion &&
        extraKey != null)
      extraKey,
  };
  if (d is! Map<String, dynamic> ||
      d.length != expected.length ||
      !d.keys.toSet().containsAll(expected)) {
    throw const FormatException();
  }
  return d;
}

final class ImportedHeadIndexSelection {
  const ImportedHeadIndexSelection._(
    this.path,
    this.indexMode,
    this.indexOid,
    this.workingHash,
    this.workingByteLength,
    this.workingRawBlob,
    this.workingExecutable,
  );
  final String path, indexMode, indexOid, workingHash, workingRawBlob;
  final int workingByteLength;
  final bool workingExecutable;
}

/// Literal read intent; saved comparisons grant no Git or mutation authority.
final class ImportedHeadIndexRequest {
  ImportedHeadIndexRequest._(
    Map<String, dynamic> d,
    List<ImportedHeadIndexSelection> files,
  ) : root = d['root'] as String,
      python = d['python'] as String,
      readId = d['read_id'] as String,
      workfileRequestDigest = d['workfile_request_sha256'] as String,
      workfileObservationDigest = d['workfile_observation_sha256'] as String,
      indexHash = d['index_sha256'] as String,
      indexByteLength = d['index_byte_length'] as int,
      objectProfile = d['object_profile'] as String?,
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
    'read_id',
    'workfile_request_sha256',
    'workfile_observation_sha256',
    'index_sha256',
    'index_byte_length',
    'selected_files',
  };
  final String root,
      python,
      readId,
      workfileRequestDigest,
      workfileObservationDigest,
      indexHash,
      requestJson;
  late final String digest;
  final int indexByteLength;
  final String? objectProfile;
  bool get supportsPackedObjects => objectProfile != null;
  final List<ImportedHeadIndexSelection> files;
  bool get authorizesCommit => false;
  bool get authorizesMutation => false;
  bool get gitStateVerified => false;
  factory ImportedHeadIndexRequest.create({
    required ImportedWorkfileRequest workfileRequest,
    required ImportedWorkfileObservation workfileObservation,
    required String readId,
  }) {
    final request = ImportedWorkfileRequest.restore(
      workfileRequest.requestJson,
    );
    final observation = ImportedWorkfileObservation.fromJson(
      workfileObservation.recordJson,
      request: request,
    );
    if (!observation.observed) {
      throw const FormatException(
        'A matching completed selected-file read is required.',
      );
    }
    return ImportedHeadIndexRequest.restore(
      jsonEncode({
        'version': 2,
        'object_profile': ImportedObjectAcquisition.profile,
        'scope': 'imported-head-index-read-request',
        'root': request.root,
        'python': request.python,
        'read_id': readId,
        'workfile_request_sha256': request.digest,
        'workfile_observation_sha256': sha256
            .convert(utf8.encode(observation.recordJson))
            .toString(),
        'index_sha256': request.indexHash,
        'index_byte_length': request.indexByteLength,
        'selected_files': [
          for (var i = 0; i < request.files.length; i++)
            {
              'path': request.files[i].path,
              'index_mode': request.files[i].mode,
              'index_oid': request.files[i].oid,
              'working_sha256': observation.files[i].hash,
              'working_byte_length': observation.files[i].byteLength,
              'working_raw_blob': observation.files[i].rawBlob,
              'working_executable': observation.files[i].executable,
            },
        ],
      }),
    );
  }
  factory ImportedHeadIndexRequest.restore(String raw) {
    try {
      final d = _decode(
        raw,
        byteLimit,
        _keys,
        extraKey: 'object_profile',
        extraVersion: 2,
      );
      if (d['version'] is! int ||
          ![1, 2].contains(d['version']) ||
          (d['version'] == 2 &&
              d['object_profile'] != ImportedObjectAcquisition.profile) ||
          d['scope'] != 'imported-head-index-read-request' ||
          d['root'] is! String ||
          d['python'] is! String ||
          d['read_id'] is! String ||
          ![
            'workfile_request_sha256',
            'workfile_observation_sha256',
            'index_sha256',
          ].every((k) => _label(d[k], 64)) ||
          d['index_byte_length'] is! int ||
          d['index_byte_length'] < 32 ||
          d['index_byte_length'] > ImportedIndexObservation.indexLimit ||
          d['selected_files'] is! List) {
        throw const FormatException();
      }
      ImportedIndexReadRequest(
        root: d['root'],
        python: d['python'],
        readId: d['read_id'],
      );
      final items = d['selected_files'] as List;
      if (items.isEmpty || items.length > 4) throw const FormatException();
      final files = <ImportedHeadIndexSelection>[];
      String? previous;
      var minimum = 32, total = 0;
      for (final item in items) {
        if (item is! Map<String, dynamic> ||
            item.length != 7 ||
            !item.keys.toSet().containsAll([
              'path',
              'index_mode',
              'index_oid',
              'working_sha256',
              'working_byte_length',
              'working_raw_blob',
              'working_executable',
            ]) ||
            item['path'] is! String ||
            !['100644', '100755'].contains(item['index_mode']) ||
            !_oid(item['index_oid']) ||
            !_label(item['working_sha256'], 64) ||
            !_oid(item['working_raw_blob']) ||
            item['working_executable'] is! bool ||
            item['working_byte_length'] is! int ||
            item['working_byte_length'] < 0 ||
            item['working_byte_length'] >
                ImportedWorkfileObservation.fileLimit) {
          throw const FormatException();
        }
        final name = item['path'] as String;
        if (previous != null && name.compareTo(previous) <= 0) {
          throw const FormatException();
        }
        minimum += ((62 + name.length + 1 + 7) ~/ 8) * 8;
        total += item['working_byte_length'] as int;
        files.add(
          ImportedHeadIndexSelection._(
            name,
            item['index_mode'] as String,
            item['index_oid'] as String,
            item['working_sha256'] as String,
            item['working_byte_length'] as int,
            item['working_raw_blob'] as String,
            item['working_executable'] as bool,
          ),
        );
        previous = name;
      }
      if (!ProjectSourceObservation.validSelection(
            files.map((f) => f.path).toList(),
          ) ||
          minimum > d['index_byte_length'] ||
          total > ImportedWorkfileObservation.aggregateLimit) {
        throw const FormatException();
      }
      return ImportedHeadIndexRequest._({
        for (final k in _keys) k: d[k],
        if (d['version'] == 2) 'object_profile': d['object_profile'],
      }, files);
    } catch (_) {
      throw const FormatException('Invalid declared-object read request.');
    }
  }
  bool matches(ImportedHeadIndexRequest other) =>
      requestJson == other.requestJson;
}

final class ImportedHeadIndexFile {
  const ImportedHeadIndexFile._(
    this.path,
    this.treeOid,
    this.treeMode,
    this.indexMatchesTree,
    this.workingBytesMatchTree,
    this.workingExecutableMatchesTree,
  );
  final String path;
  final String? treeOid, treeMode;
  final bool indexMatchesTree,
      workingBytesMatchTree,
      workingExecutableMatchesTree;
}

enum ImportedHeadIndexStatus { observed, refused, stopped }

/// Content-identified declared objects, not authenticated Git state.
final class ImportedHeadIndexObservation {
  ImportedHeadIndexObservation._(
    this.status,
    this.requestDigest,
    this.reason,
    this.referenceAcquisition,
    this.objectAcquisition,
    this.headForm,
    this.declaredRef,
    this.headOid,
    this.treeOid,
    this.indexHash,
    this.objectCount,
    this.objectBytes,
    List<ImportedHeadIndexFile> files,
    this.recordedAt,
    this.recordJson,
  ) : files = List.unmodifiable(files);
  static const responseLimit = 32 * 1024,
      objectByteLimit = 256 * 1024,
      objectCountLimit = 70;
  static const _unknown = {
    'git_state_verified': false,
    'repository_authenticated': false,
    'working_tree': 'unknown',
    'head_membership': 'unknown',
    'filters': 'unknown',
    'untracked': 'unknown',
    'commit_authorized': false,
    'mutation_authorized': false,
  };
  static const _keys = {
    'version',
    'scope',
    'request_sha256',
    'read_id',
    'root',
    'status',
    'reason',
    'acquisition',
    'reference_acquisition',
    'head_form',
    'declared_ref',
    'head_oid',
    'tree_oid',
    'index_sha256',
    'object_count',
    'object_bytes',
    'files',
    'git_state_verified',
    'repository_authenticated',
    'working_tree',
    'head_membership',
    'filters',
    'untracked',
    'commit_authorized',
    'mutation_authorized',
    'recorded_at',
  };
  final ImportedHeadIndexStatus status;
  final String requestDigest, recordJson;
  final ImportedReferenceAcquisition? referenceAcquisition;
  final ImportedObjectAcquisition? objectAcquisition;
  final String? reason, headForm, declaredRef, headOid, treeOid, indexHash;
  final int objectCount, objectBytes;
  final List<ImportedHeadIndexFile> files;
  final DateTime recordedAt;
  bool get observed => status == ImportedHeadIndexStatus.observed;
  bool get authorizesCommit => false;
  bool get authorizesMutation => false;
  bool get gitStateVerified => false;
  bool get repositoryAuthenticated => false;
  String get workingTree => 'unknown';
  String get headMembership => 'unknown';
  String get filters => 'unknown';
  String get untracked => 'unknown';
  factory ImportedHeadIndexObservation.fromJson(
    String raw, {
    required ImportedHeadIndexRequest request,
  }) {
    try {
      final d = _decode(
        raw,
        responseLimit,
        _keys,
        extraKey: 'object_acquisition',
        extraVersion: 3,
      );
      if (d['version'] is! int ||
          d['version'] != (request.supportsPackedObjects ? 3 : 2) ||
          d['scope'] != 'imported-head-index-observation' ||
          d['request_sha256'] != request.digest ||
          d['read_id'] != request.readId ||
          d['root'] != request.root ||
          _unknown.entries.any((e) => d[e.key] != e.value) ||
          d['object_count'] is! int ||
          d['object_bytes'] is! int ||
          d['files'] is! List ||
          d['recorded_at'] is! String) {
        throw const FormatException();
      }
      final status = ImportedHeadIndexStatus.values.singleWhere(
        (s) => s.name == d['status'],
      );
      final items = d['files'] as List;
      final files = <ImportedHeadIndexFile>[];
      ImportedReferenceAcquisition? referenceAcquisition;
      ImportedObjectAcquisition? objectAcquisition;
      if (status == ImportedHeadIndexStatus.observed) {
        if (d['reason'] != null ||
            d['acquisition'] !=
                (request.supportsPackedObjects
                    ? ImportedObjectAcquisition.profile
                    : 'direct-loose-object-files') ||
            !_oid(d['head_oid']) ||
            !_oid(d['tree_oid']) ||
            d['index_sha256'] != request.indexHash ||
            d['object_count'] < 2 ||
            d['object_count'] > objectCountLimit ||
            d['object_bytes'] < 1 ||
            d['object_bytes'] > objectByteLimit ||
            items.length != request.files.length) {
          throw const FormatException();
        }
        if (request.supportsPackedObjects) {
          objectAcquisition = ImportedObjectAcquisition.fromMap(
            d['object_acquisition'],
          );
          if (!objectAcquisition.matchesTotals(
            count: d['object_count'] as int,
            bytes: d['object_bytes'] as int,
          )) {
            throw const FormatException();
          }
        }
        referenceAcquisition = ImportedReferenceAcquisition.fromMap(
          d['reference_acquisition'],
        );
        if (!referenceAcquisition.matchesHeadForm(d['head_form'] as String?)) {
          throw const FormatException();
        }
        // This parser checks only HEAD/reference syntax; acquisition stays typed above.
        GitHeadObservation.parse(
          jsonEncode({
            'version': 1,
            'layout': 'direct-dotgit-files',
            'scope': 'literal-file-declarations',
            'status': 'observed',
            'head_form': d['head_form'],
            'declared_ref': d['declared_ref'],
            'declared_oid': d['head_oid'],
            'oid_source': d['head_form'] == 'symbolic' ? 'loose_ref' : 'head',
            'reason': null,
            'git_state_verified': false,
            'working_tree': 'unknown',
            'ahead_behind': 'unknown',
            'conflict': 'unknown',
          }),
        );
        for (var i = 0; i < items.length; i++) {
          final item = items[i], selected = request.files[i];
          if (item is! Map<String, dynamic> ||
              item.length != 6 ||
              !item.keys.toSet().containsAll([
                'path',
                'tree_oid',
                'tree_mode',
                'index_matches_tree',
                'working_bytes_match_tree',
                'working_executable_matches_tree',
              ]) ||
              item['path'] != selected.path ||
              item['index_matches_tree'] is! bool ||
              item['working_bytes_match_tree'] is! bool ||
              item['working_executable_matches_tree'] is! bool) {
            throw const FormatException();
          }
          final absent = item['tree_oid'] == null && item['tree_mode'] == null;
          if (!absent &&
              (!_oid(item['tree_oid']) ||
                  !['100644', '100755'].contains(item['tree_mode']))) {
            throw const FormatException();
          }
          if (item['index_matches_tree'] !=
                  (!absent &&
                      item['tree_oid'] == selected.indexOid &&
                      item['tree_mode'] == selected.indexMode) ||
              item['working_bytes_match_tree'] !=
                  (!absent && item['tree_oid'] == selected.workingRawBlob) ||
              item['working_executable_matches_tree'] !=
                  (!absent &&
                      selected.workingExecutable ==
                          (item['tree_mode'] == '100755'))) {
            throw const FormatException();
          }
          files.add(
            ImportedHeadIndexFile._(
              selected.path,
              item['tree_oid'] as String?,
              item['tree_mode'] as String?,
              item['index_matches_tree'] as bool,
              item['working_bytes_match_tree'] as bool,
              item['working_executable_matches_tree'] as bool,
            ),
          );
        }
      } else {
        const reasons = {
          'unsupported_layout',
          'missing_loose_object',
          'invalid_object',
          'bounds',
          'changed',
          'index_changed',
          'working_file_changed',
          'invalid_request',
          'unavailable',
          'stopped',
        };
        if (d['object_acquisition'] != null ||
            items.isNotEmpty ||
            !reasons.contains(d['reason']) ||
            ((status == ImportedHeadIndexStatus.stopped) !=
                (d['reason'] == 'stopped')) ||
            d['object_count'] != 0 ||
            d['object_bytes'] != 0 ||
            [
              'acquisition',
              'reference_acquisition',
              'head_form',
              'declared_ref',
              'head_oid',
              'tree_oid',
              'index_sha256',
            ].any((k) => d[k] != null)) {
          throw const FormatException();
        }
      }
      final at = DateTime.parse(d['recorded_at'] as String).toUtc();
      if (at.toIso8601String() != d['recorded_at']) {
        throw const FormatException();
      }
      return ImportedHeadIndexObservation._(
        status,
        request.digest,
        d['reason'] as String?,
        referenceAcquisition,
        objectAcquisition,
        d['head_form'] as String?,
        d['declared_ref'] as String?,
        d['head_oid'] as String?,
        d['tree_oid'] as String?,
        d['index_sha256'] as String?,
        d['object_count'] as int,
        d['object_bytes'] as int,
        files,
        at,
        jsonEncode({
          for (final k in _keys) k: d[k],
          if (d['version'] == 3) 'object_acquisition': d['object_acquisition'],
        }),
      );
    } catch (_) {
      throw const FormatException('Invalid declared-object observation.');
    }
  }
}

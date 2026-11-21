// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_commit_copy_request.dart';
import 'structured_proposal_json.dart';

/// Explicit read intent. It selects no command or caller-controlled metadata file.
final class ImportedIndexReadRequest {
  ImportedIndexReadRequest._(
    this.root,
    this.python,
    this.readId,
    this.requestJson,
  ) : digest = sha256.convert(utf8.encode(requestJson)).toString();
  final String root, python, readId, requestJson, digest;
  static const byteLimit = 16 * 1024;
  factory ImportedIndexReadRequest({
    required String root,
    required String python,
    required String readId,
  }) => ImportedIndexReadRequest.restore(
    jsonEncode({
      'version': 1,
      'scope': 'imported-index-read-request',
      'root': root,
      'python': python,
      'read_id': readId,
    }),
  );
  factory ImportedIndexReadRequest.restore(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final d = jsonDecode(raw);
      const keys = ['version', 'scope', 'root', 'python', 'read_id'];
      if (d is! Map<String, dynamic> ||
          d.length != keys.length ||
          !d.keys.toSet().containsAll(keys) ||
          d['version'] is! int ||
          d['version'] != 1 ||
          d['scope'] != 'imported-index-read-request' ||
          ['root', 'python', 'read_id'].any((k) => d[k] is! String)) {
        throw const FormatException();
      }
      final root = d['root'] as String,
          python = d['python'] as String,
          id = d['read_id'] as String;
      bool inside(String parent, String child) =>
          child.toLowerCase() == parent.toLowerCase() ||
          child.toLowerCase().startsWith('${parent.toLowerCase()}/');
      for (final value in [root, python]) {
        if (!ImportedCommitCopyRequest.validPath(value) ||
            utf8.decode([32, ...utf8.encode(value)]).substring(1) != value) {
          throw const FormatException();
        }
      }
      if (inside(root, python) ||
          inside(python, root) ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
          id == '0' * 32) {
        throw const FormatException();
      }
      return ImportedIndexReadRequest._(
        root,
        python,
        id,
        jsonEncode({for (final k in keys) k: d[k]}),
      );
    } catch (_) {
      throw const FormatException('Invalid original-index read request.');
    }
  }
  bool matches(ImportedIndexReadRequest other) =>
      requestJson == other.requestJson;
  bool get authorizesCommit => false;
  bool get authorizesMutation => false;
}

enum ImportedIndexStatus {
  observed,
  unsupported,
  invalid,
  changed,
  unavailable,
  stopped,
}

/// Literal index declarations. Object labels do not establish object membership.
final class ImportedIndexEntry {
  const ImportedIndexEntry._(this.path, this.mode, this.oid);
  final String path, mode, oid;
}

/// A dated bounded observation, never Git status or mutation/commit authority.
final class ImportedIndexObservation {
  ImportedIndexObservation._(
    this.status,
    this.requestDigest,
    this.reason,
    this.indexHash,
    this.indexByteLength,
    List<ImportedIndexEntry> entries,
    List<String> optionalCaches,
    this.recordedAt,
    this.recordJson,
  ) : entries = List.unmodifiable(entries),
      optionalCaches = List.unmodifiable(optionalCaches);
  static const responseLimit = 512 * 1024, indexLimit = 256 * 1024;
  final ImportedIndexStatus status;
  final String requestDigest, recordJson;
  final String? reason, indexHash;
  final int? indexByteLength;
  final List<ImportedIndexEntry> entries;
  final List<String> optionalCaches;
  final DateTime recordedAt;
  bool get gitStateVerified => false;
  bool get authorizesCommit => false;
  bool get authorizesMutation => false;
  String get workingTree => 'unknown';
  String get headMembership => 'unknown';
  bool get observed => status == ImportedIndexStatus.observed;
  factory ImportedIndexObservation.fromJson(
    String raw, {
    required ImportedIndexReadRequest request,
  }) {
    try {
      if (raw.length > responseLimit ||
          utf8.encode(raw).length > responseLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final d = jsonDecode(raw);
      const keys = [
        'version',
        'scope',
        'request_sha256',
        'read_id',
        'root',
        'status',
        'reason',
        'format',
        'index_sha256',
        'index_byte_length',
        'optional_caches',
        'entries',
        'git_state_verified',
        'working_tree',
        'head_membership',
        'commit_authorized',
        'mutation_authorized',
        'recorded_at',
      ];
      if (d is! Map<String, dynamic> ||
          d.length != keys.length ||
          !d.keys.toSet().containsAll(keys) ||
          d['version'] is! int ||
          d['version'] != 1 ||
          d['scope'] != 'imported-index-observation' ||
          d['request_sha256'] != request.digest ||
          d['read_id'] != request.readId ||
          d['root'] != request.root ||
          d['git_state_verified'] != false ||
          d['working_tree'] != 'unknown' ||
          d['head_membership'] != 'unknown' ||
          d['commit_authorized'] != false ||
          d['mutation_authorized'] != false ||
          d['recorded_at'] is! String ||
          d['entries'] is! List ||
          (d['entries'] as List).length > 2048 ||
          d['optional_caches'] is! List) {
        throw const FormatException();
      }
      final status = ImportedIndexStatus.values.singleWhere(
        (s) => s.name == d['status'],
      );
      final entries = <ImportedIndexEntry>[];
      final seen = <String>{};
      String? previous;
      var minimumBytes = 32;
      for (final item in d['entries'] as List) {
        if (item is! Map<String, dynamic> ||
            item.length != 3 ||
            !item.keys.toSet().containsAll(['path', 'mode', 'oid']) ||
            ['path', 'mode', 'oid'].any((k) => item[k] is! String)) {
          throw const FormatException();
        }
        final path = item['path'] as String,
            mode = item['mode'] as String,
            oid = item['oid'] as String;
        if (path.isEmpty ||
            path.length > 1024 ||
            !RegExp(r'^[A-Za-z0-9_. @+()/\-]+$').hasMatch(path) ||
            path
                .split('/')
                .any(
                  (p) => ['', '.', '..', '.git'].contains(p.toLowerCase()),
                ) ||
            !['100644', '100755'].contains(mode) ||
            !RegExp(r'^[a-f0-9]{40}$').hasMatch(oid) ||
            oid == '0' * 40 ||
            !seen.add(path.toLowerCase()) ||
            (previous != null && path.compareTo(previous) <= 0)) {
          throw const FormatException();
        }
        minimumBytes += ((62 + path.length + 1 + 7) ~/ 8) * 8;
        previous = path;
        entries.add(ImportedIndexEntry._(path, mode, oid));
      }
      final caches = d['optional_caches'] as List;
      if (caches.length > 1 || caches.any((c) => c != 'TREE')) {
        throw const FormatException();
      }
      minimumBytes += caches.length * 8;
      if (status == ImportedIndexStatus.observed) {
        if (d['reason'] != null ||
            d['format'] != 'index-v2-sha1' ||
            d['index_sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(d['index_sha256'] as String) ||
            d['index_byte_length'] is! int ||
            d['index_byte_length'] < minimumBytes ||
            d['index_byte_length'] > indexLimit) {
          throw const FormatException();
        }
      } else {
        const reasons = {
          ImportedIndexStatus.unsupported: {
            'host',
            'layout',
            'format',
            'entry',
            'extension',
          },
          ImportedIndexStatus.invalid: {
            'checksum',
            'bounds',
            'path',
            'encoding',
            'malformed',
            'missing_index',
          },
          ImportedIndexStatus.changed: {
            'metadata_changed',
            'lock_changed',
            'layout_changed',
          },
          ImportedIndexStatus.unavailable: {
            'read_unavailable',
            'invalid_request',
          },
          ImportedIndexStatus.stopped: {'stopped'},
        };
        if (entries.isNotEmpty ||
            caches.isNotEmpty ||
            d['format'] != null ||
            d['index_sha256'] != null ||
            d['index_byte_length'] != null ||
            !(reasons[status]?.contains(d['reason']) ?? false)) {
          throw const FormatException();
        }
      }
      final at = DateTime.parse(d['recorded_at'] as String).toUtc();
      if (at.toIso8601String() != d['recorded_at']) {
        throw const FormatException();
      }
      return ImportedIndexObservation._(
        status,
        request.digest,
        d['reason'] as String?,
        d['index_sha256'] as String?,
        d['index_byte_length'] as int?,
        entries,
        List<String>.from(caches),
        at,
        jsonEncode({for (final k in keys) k: d[k]}),
      );
    } catch (_) {
      throw const FormatException('Invalid original-index observation.');
    }
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'structured_proposal_json.dart';

bool _hash(Object? value, int size) =>
    value is String && RegExp('^[a-f0-9]{$size}\$').hasMatch(value);
bool _number(Object? value, int minimum, int maximum) =>
    value is int && value >= minimum && value <= maximum;
Map<String, dynamic> _map(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.toSet().containsAll(keys)) {
    throw const FormatException();
  }
  return value;
}

/// A verified index declaration, distinct from unread pack contents.
final class ImportedPackIndexAcquisition {
  const ImportedPackIndexAcquisition._(
    this.indexHash,
    this.indexByteLength,
    this.declaredPackChecksum,
    this.packFileBytes,
    this.objectCount,
  );
  final String indexHash, declaredPackChecksum;
  final int indexByteLength, packFileBytes, objectCount;
  bool get wholePackIntegrityVerified => false;

  factory ImportedPackIndexAcquisition.fromMap(Object? value) {
    final d = _map(value, {
      'index_sha256',
      'index_byte_length',
      'declared_pack_sha1',
      'pack_file_bytes',
      'object_count',
    });
    if (!_hash(d['index_sha256'], 64) ||
        !_hash(d['declared_pack_sha1'], 40) ||
        d['declared_pack_sha1'] == '0' * 40 ||
        !_number(d['object_count'], 1, 16384) ||
        !_number(d['index_byte_length'], 1100, 524288) ||
        d['index_byte_length'] != 1072 + 28 * (d['object_count'] as int) ||
        !_number(d['pack_file_bytes'], 32, 67108864)) {
      throw const FormatException('Invalid pack index declaration.');
    }
    return ImportedPackIndexAcquisition._(
      d['index_sha256'] as String,
      d['index_byte_length'] as int,
      d['declared_pack_sha1'] as String,
      d['pack_file_bytes'] as int,
      d['object_count'] as int,
    );
  }
}

/// Bounded acquisition provenance. This grants no Git or write authority.
final class ImportedObjectAcquisition {
  ImportedObjectAcquisition._(
    this.looseObjectCount,
    this.packedObjectCount,
    this.encodedBytes,
    this.expandedBytes,
    this.maxDeltaDepth,
    List<ImportedPackIndexAcquisition> indexes,
  ) : indexes = List.unmodifiable(indexes);

  static const profile = 'bounded-loose-pack2-index2-v1';
  static const byteLimit = 4096;
  final int looseObjectCount,
      packedObjectCount,
      encodedBytes,
      expandedBytes,
      maxDeltaDepth;
  final List<ImportedPackIndexAcquisition> indexes;
  int get objectCount => looseObjectCount + packedObjectCount;
  bool get wholePackIntegrityVerified => false;
  bool get repositoryAuthenticated => false;
  bool get authorizesCommit => false;
  bool get authorizesMutation => false;

  factory ImportedObjectAcquisition.fromJson(String raw) {
    if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
      throw const FormatException('Invalid object acquisition.');
    }
    rejectDuplicateJsonMembers(raw);
    return ImportedObjectAcquisition.fromMap(jsonDecode(raw));
  }

  /// Parent JSON decoders must reject duplicate members first.
  factory ImportedObjectAcquisition.fromMap(Object? value) {
    try {
      final d = _map(value, {
        'profile',
        'loose_object_count',
        'packed_object_count',
        'encoded_bytes',
        'expanded_bytes',
        'max_delta_depth',
        'indexes',
        'whole_pack_integrity_verified',
      });
      if (d['profile'] != profile ||
          d['whole_pack_integrity_verified'] != false ||
          !_number(d['loose_object_count'], 0, 70) ||
          !_number(d['packed_object_count'], 0, 70) ||
          !_number(d['encoded_bytes'], 0, 524288) ||
          !_number(d['expanded_bytes'], 1, 262144) ||
          !_number(d['max_delta_depth'], 0, 32) ||
          d['indexes'] is! List) {
        throw const FormatException();
      }
      final loose = d['loose_object_count'] as int,
          packed = d['packed_object_count'] as int,
          items = d['indexes'] as List;
      if (loose + packed < 2 || loose + packed > 70 || items.length > 4) {
        throw const FormatException();
      }
      if (packed == 0
          ? items.isNotEmpty ||
                d['encoded_bytes'] != 0 ||
                d['max_delta_depth'] != 0
          : items.isEmpty || (d['encoded_bytes'] as int) < 9) {
        throw const FormatException();
      }
      final indexes = <ImportedPackIndexAcquisition>[];
      String? previous;
      var total = 0, declaredObjects = 0;
      for (final item in items) {
        final index = ImportedPackIndexAcquisition.fromMap(item);
        if (previous != null &&
            previous.compareTo(index.declaredPackChecksum) >= 0) {
          throw const FormatException();
        }
        total += index.indexByteLength;
        declaredObjects += index.objectCount;
        if (total > 524288) throw const FormatException();
        previous = index.declaredPackChecksum;
        indexes.add(index);
      }
      if (packed > 0 &&
          ((d['encoded_bytes'] as int) < 9 * packed ||
              (d['encoded_bytes'] as int) > 131072 * packed ||
              (d['max_delta_depth'] as int) >= packed ||
              packed > declaredObjects)) {
        throw const FormatException();
      }
      return ImportedObjectAcquisition._(
        loose,
        packed,
        d['encoded_bytes'] as int,
        d['expanded_bytes'] as int,
        d['max_delta_depth'] as int,
        indexes,
      );
    } catch (_) {
      throw const FormatException('Invalid object acquisition.');
    }
  }

  bool matchesTotals({required int count, required int bytes}) =>
      objectCount == count && expandedBytes == bytes;
}

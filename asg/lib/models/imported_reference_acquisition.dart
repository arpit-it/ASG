// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'structured_proposal_json.dart';

enum ImportedReferenceSource { head, looseRef, packedRef }

/// Bounded literal acquisition labels. No repository or mutation authority.
/// The owning observation must also bind these facts to its request and HEAD.
final class ImportedReferenceAcquisition {
  const ImportedReferenceAcquisition._(
    this.source,
    this.packedRefsHash,
    this.packedRefsByteLength,
    this.packedRefsEntryCount,
  );

  static const byteLimit = 1024;
  static const packedHeaderByteLength = 46;
  static const packedByteLimit = 256 * 1024;
  static const packedEntryLimit = 2048;
  static const _keys = {
    'source',
    'packed_refs_sha256',
    'packed_refs_byte_length',
    'packed_refs_entry_count',
  };
  static const _sources = {
    'head': ImportedReferenceSource.head,
    'loose_ref': ImportedReferenceSource.looseRef,
    'packed_ref': ImportedReferenceSource.packedRef,
  };

  final ImportedReferenceSource source;
  final String? packedRefsHash;
  final int? packedRefsByteLength, packedRefsEntryCount;
  bool get hasPackedRefs => packedRefsHash != null;
  bool get repositoryAuthenticated => false;
  bool get authorizesCommit => false;
  bool get authorizesMutation => false;

  bool matchesHeadForm(String? form) => source == ImportedReferenceSource.head
      ? form == 'direct_oid'
      : form == 'symbolic';

  factory ImportedReferenceAcquisition.fromJson(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      return ImportedReferenceAcquisition.fromMap(jsonDecode(raw));
    } catch (_) {
      throw const FormatException('Invalid reference acquisition.');
    }
  }

  /// Parent decoders must reject duplicate members before passing decoded maps.
  factory ImportedReferenceAcquisition.fromMap(Object? value) {
    try {
      if (value is! Map<String, dynamic> ||
          value.length != _keys.length ||
          !value.keys.toSet().containsAll(_keys) ||
          !_sources.containsKey(value['source'])) {
        throw const FormatException();
      }
      final source = _sources[value['source']]!;
      final hash = value['packed_refs_sha256'];
      final bytes = value['packed_refs_byte_length'];
      final count = value['packed_refs_entry_count'];
      if (hash == null && bytes == null && count == null) {
        if (source == ImportedReferenceSource.packedRef) {
          throw const FormatException();
        }
      } else if (hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          bytes is! int ||
          count is! int ||
          bytes < packedHeaderByteLength ||
          bytes > packedByteLimit ||
          count < 0 ||
          count > packedEntryLimit ||
          bytes < packedHeaderByteLength + 53 * count ||
          (count == 0 && bytes != packedHeaderByteLength) ||
          (source == ImportedReferenceSource.packedRef && count == 0)) {
        throw const FormatException();
      }
      return ImportedReferenceAcquisition._(
        source,
        hash as String?,
        bytes as int?,
        count as int?,
      );
    } catch (_) {
      throw const FormatException('Invalid reference acquisition.');
    }
  }

  Map<String, Object?> toJson() => {
    'source': _sources.entries.singleWhere((e) => e.value == source).key,
    'packed_refs_sha256': packedRefsHash,
    'packed_refs_byte_length': packedRefsByteLength,
    'packed_refs_entry_count': packedRefsEntryCount,
  };
  String get recordJson => jsonEncode(toJson());
}

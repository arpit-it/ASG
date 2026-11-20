// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'imported_source_proposal_record.dart';
import 'project_source_observation.dart';

enum ImportedSourceBaselineStatus { matched, changed, refused }

final class ImportedSourceBaselineFile {
  ImportedSourceBaselineFile._(
    this.path,
    this.beforeHash,
    this.afterHash,
    this.beforeByteLength,
    this.afterByteLength,
    this.matches,
  );
  final String path, beforeHash;
  final String? afterHash;
  final int beforeByteLength;
  final int? afterByteLength;
  final bool matches;
}

/// Supplied observation/app-request identities, never current disk or approval proof.
/// Callers must separately bind consent, current app inputs and owned host cleanup.
final class ImportedSourceBaseline {
  ImportedSourceBaseline._(
    this.root,
    this.savedRecordDigest,
    this.requestDigest,
    this.observationDigest,
    this.observedAt,
    this.status,
    this.reason,
    List<ImportedSourceBaselineFile> files,
    this.recordJson,
    this.digest,
  ) : files = List.unmodifiable(files);
  static const recordByteLimit = 16 * 1024;
  final String root, savedRecordDigest, requestDigest, observationDigest;
  final DateTime observedAt;
  final ImportedSourceBaselineStatus status;
  final String? reason;
  final List<ImportedSourceBaselineFile> files;
  final String recordJson, digest;
  bool get sourceVerified => false;
  bool get matched => status == ImportedSourceBaselineStatus.matched;
  List<String> get changedPaths => List.unmodifiable(
    status == ImportedSourceBaselineStatus.changed
        ? files.where((f) => !f.matches).map((f) => f.path)
        : <String>[],
  );

  static bool _same<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _absolute(String value) =>
      value.length <= 4096 &&
      utf8.encode(value).length <= 4096 &&
      utf8.decode(utf8.encode(value)) == value &&
      path.isAbsolute(value) &&
      path.normalize(value) == value &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

  factory ImportedSourceBaseline.compare({
    required ImportedSourceProposalRecord saved,
    required ProjectSourceReadRequest request,
    required ProjectSourceObservation observation,
    required DateTime observedAt,
  }) {
    try {
      final before = saved.context.files;
      final selected = before.map((f) => f.path).toList();
      if (!_absolute(request.root) ||
          request.root == path.separator ||
          !_absolute(request.python) ||
          request.root != saved.root ||
          path.equals(
            request.root.toLowerCase(),
            request.python.toLowerCase(),
          ) ||
          path.isWithin(
            request.root.toLowerCase(),
            request.python.toLowerCase(),
          ) ||
          !_same(request.selectedPaths, selected) ||
          !_same(observation.selectedPaths, selected)) {
        throw const FormatException();
      }
      final observed = observation.status == ProjectSourceStatus.observed;
      if (observed &&
          (observation.files.length != before.length ||
              observation.reason != null)) {
        throw const FormatException();
      }
      if (!observed &&
          (observation.files.isNotEmpty || observation.reason == null)) {
        throw const FormatException();
      }
      final files = <ImportedSourceBaselineFile>[];
      for (var i = 0; i < before.length; i++) {
        final a = before[i];
        final b = observed ? observation.files[i] : null;
        if (b != null && a.path != b.path) throw const FormatException();
        final matches =
            b != null &&
            a.byteLength == b.byteLength &&
            a.digest == b.digest &&
            a.text == b.text &&
            _same(a.bytes, b.bytes);
        files.add(
          ImportedSourceBaselineFile._(
            a.path,
            a.digest,
            b?.digest,
            a.byteLength,
            b?.byteLength,
            matches,
          ),
        );
      }
      final status = !observed
          ? ImportedSourceBaselineStatus.refused
          : files.every((f) => f.matches)
          ? ImportedSourceBaselineStatus.matched
          : ImportedSourceBaselineStatus.changed;
      final requestJson = jsonEncode({
        'root': request.root,
        'python': request.python,
        'selected_paths': request.selectedPaths,
      });
      final observationJson = jsonEncode({
        'version': 1,
        'scope': 'project-source-files',
        'status': observation.status.name,
        'reason': observation.reason,
        'selected_paths': observation.selectedPaths,
        'source_verified': false,
        'files': [
          for (final file in observation.files)
            {
              'path': file.path,
              'byte_length': file.byteLength,
              'sha256': file.digest,
              'content_base64': base64Encode(file.bytes),
            },
        ],
      });
      if (utf8.encode(observationJson).length >
          ProjectSourceObservation.responseLimit) {
        throw const FormatException();
      }
      final requestDigest = sha256.convert(utf8.encode(requestJson)).toString();
      final observationDigest = sha256
          .convert(utf8.encode(observationJson))
          .toString();
      final time = observedAt.toUtc();
      final record = jsonEncode({
        'version': 1,
        'scope': 'imported-source-baseline',
        'source_verified': false,
        'root': saved.root,
        'saved_record_sha256': saved.digest,
        'request_sha256': requestDigest,
        'observation_sha256': observationDigest,
        'observed_at': time.toIso8601String(),
        'status': status.name,
        'reason': observation.reason,
        'files': [
          for (final file in files)
            {
              'path': file.path,
              'before_sha256': file.beforeHash,
              'after_sha256': file.afterHash,
              'before_byte_length': file.beforeByteLength,
              'after_byte_length': file.afterByteLength,
              'matches': file.matches,
            },
        ],
      });
      if (utf8.encode(record).length > recordByteLimit) {
        throw const FormatException();
      }
      return ImportedSourceBaseline._(
        saved.root,
        saved.digest,
        requestDigest,
        observationDigest,
        time,
        status,
        observation.reason,
        files,
        record,
        sha256.convert(utf8.encode(record)).toString(),
      );
    } catch (_) {
      throw const FormatException(
        'Source baseline comparison inputs are invalid or exceed local limits.',
      );
    }
  }
}

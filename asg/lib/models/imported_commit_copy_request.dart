// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'imported_commit_proposal_record.dart';
import 'imported_commit_source_observation.dart';
import 'project_source_observation.dart';
import 'structured_proposal_json.dart';

/// Supplied immutable baseline-copy intent, not current consent or host admission.
/// The controller must independently fence current durable inputs before dispatch.
final class ImportedCommitCopyRequest {
  ImportedCommitCopyRequest._({
    required this.root,
    required this.python,
    required this.destination,
    required this.attemptId,
    required this.commit,
    required this.tree,
    required this.manifestDigest,
    required this.manifestFiles,
    required this.contextDigest,
    required this.planDigest,
    required this.proposalDigest,
    required this.historyDigest,
    required this.requestJson,
    required this.digest,
    required this.selectedFiles,
  });

  static const byteLimit = 32 * 1024;
  final String root, python, destination, attemptId, commit, tree;
  final String manifestDigest, contextDigest, planDigest;
  final String proposalDigest, historyDigest, requestJson, digest;
  final int manifestFiles;
  final List<ImportedCommitCopyFile> selectedFiles;

  bool get appliesReplacement => false;
  bool get sourceVerified => false;
  bool matches(ImportedCommitCopyRequest other) =>
      requestJson == other.requestJson;

  factory ImportedCommitCopyRequest.create({
    required ImportedCommitProposalRecord saved,
    required String python,
    required String destination,
    required String attemptId,
  }) {
    try {
      // Revalidate the historical identity; it still does not establish current
      // approval, a live folder, destination permission or full-copy eligibility.
      final checked = ImportedCommitProposalRecord.decode(saved.encode());
      final root = checked.root;
      if (![root, python, destination].every(validPath) ||
          !_attempt.hasMatch(attemptId) ||
          attemptId == '0' * 32 ||
          _inside(root, destination) ||
          _inside(root, python) ||
          _inside(destination, python)) {
        throw const FormatException();
      }
      final context = checked.context, proposal = checked.proposal;
      final raw = jsonEncode({
        'version': 1,
        'scope': 'imported-commit-copy-request',
        'attempt_id': attemptId,
        'root': root,
        'python': python,
        'destination': destination,
        'commit': context.commit,
        'tree': context.tree,
        'manifest_sha256': context.manifestDigest,
        'manifest_files': context.manifestFiles,
        'context_sha256': context.digest,
        'plan_sha256': proposal.planDigest,
        'proposal_sha256': proposal.digest,
        'history_sha256': checked.digest,
        'selected_files': [
          for (final file in context.files)
            {
              'path': file.source.path,
              'mode': file.mode,
              'git_blob': file.gitBlob,
              'sha256': file.source.digest,
              'byte_length': file.source.byteLength,
            },
        ],
      });
      return ImportedCommitCopyRequest.restore(raw);
    } catch (_) {
      throw const FormatException('Invalid immutable baseline-copy request.');
    }
  }

  /// Restores supplied historical intent only; no current approval or effects.
  factory ImportedCommitCopyRequest.restore(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      final data = jsonDecode(raw);
      rejectDuplicateJsonMembers(raw);
      const keys = {
        'version',
        'scope',
        'attempt_id',
        'root',
        'python',
        'destination',
        'commit',
        'tree',
        'manifest_sha256',
        'manifest_files',
        'context_sha256',
        'plan_sha256',
        'proposal_sha256',
        'history_sha256',
        'selected_files',
      };
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'imported-commit-copy-request') {
        throw const FormatException();
      }
      final root = data['root'] as String;
      final python = data['python'] as String;
      final destination = data['destination'] as String;
      final attempt = data['attempt_id'] as String;
      if (![root, python, destination].every(validPath) ||
          !_attempt.hasMatch(attempt) ||
          attempt == '0' * 32 ||
          _inside(root, destination) ||
          _inside(root, python) ||
          _inside(destination, python) ||
          !['commit', 'tree'].every(
            (k) =>
                data[k] is String &&
                ImportedCommitReadRequest.validCommit(data[k] as String),
          ) ||
          ![
            'manifest_sha256',
            'context_sha256',
            'plan_sha256',
            'proposal_sha256',
            'history_sha256',
          ].every(
            (k) => data[k] is String && _sha.hasMatch(data[k] as String),
          ) ||
          data['manifest_files'] is! int ||
          data['manifest_files'] < 1 ||
          data['manifest_files'] > 2048 ||
          data['selected_files'] is! List) {
        throw const FormatException();
      }
      final files = <ImportedCommitCopyFile>[];
      for (final entry in data['selected_files'] as List) {
        if (entry is! Map<String, dynamic> ||
            entry.length != 5 ||
            !entry.keys.toSet().containsAll({
              'path',
              'mode',
              'git_blob',
              'sha256',
              'byte_length',
            }) ||
            entry['path'] is! String ||
            !{'100644', '100755'}.contains(entry['mode']) ||
            entry['git_blob'] is! String ||
            !ImportedCommitReadRequest.validCommit(
              entry['git_blob'] as String,
            ) ||
            entry['sha256'] is! String ||
            !_sha.hasMatch(entry['sha256'] as String) ||
            entry['byte_length'] is! int ||
            entry['byte_length'] < 0 ||
            entry['byte_length'] > 32768) {
          throw const FormatException();
        }
        files.add(
          ImportedCommitCopyFile._(
            entry['path'] as String,
            entry['mode'] as String,
            entry['git_blob'] as String,
            entry['sha256'] as String,
            entry['byte_length'] as int,
          ),
        );
      }
      if (!ProjectSourceObservation.validSelection(
            files.map((f) => f.path).toList(),
          ) ||
          files.length > data['manifest_files'] ||
          files.fold<int>(0, (sum, f) => sum + f.byteLength) > 65536) {
        throw const FormatException();
      }
      final canonical = jsonEncode({
        'version': 1,
        'scope': 'imported-commit-copy-request',
        'attempt_id': attempt,
        'root': root,
        'python': python,
        'destination': destination,
        'commit': data['commit'],
        'tree': data['tree'],
        'manifest_sha256': data['manifest_sha256'],
        'manifest_files': data['manifest_files'],
        'context_sha256': data['context_sha256'],
        'plan_sha256': data['plan_sha256'],
        'proposal_sha256': data['proposal_sha256'],
        'history_sha256': data['history_sha256'],
        'selected_files': files.map((f) => f.toJson()).toList(),
      });
      if (canonical != raw) throw const FormatException();
      return ImportedCommitCopyRequest._(
        root: root,
        python: python,
        destination: destination,
        attemptId: attempt,
        commit: data['commit'] as String,
        tree: data['tree'] as String,
        manifestDigest: data['manifest_sha256'] as String,
        manifestFiles: data['manifest_files'] as int,
        contextDigest: data['context_sha256'] as String,
        planDigest: data['plan_sha256'] as String,
        proposalDigest: data['proposal_sha256'] as String,
        historyDigest: data['history_sha256'] as String,
        requestJson: raw,
        digest: sha256.convert(utf8.encode(raw)).toString(),
        selectedFiles: List.unmodifiable(files),
      );
    } catch (_) {
      throw const FormatException('Invalid immutable baseline-copy request.');
    }
  }

  static final _sha = RegExp(r'^[a-f0-9]{64}$');
  static final _attempt = RegExp(r'^[a-f0-9]{32}$');

  static bool validPath(String value) =>
      path.posix.isAbsolute(value) &&
      value != '/' &&
      !value.startsWith('//') &&
      path.posix.normalize(value) == value &&
      utf8.encode(value).length <= 4096 &&
      utf8.decode(utf8.encode(value)) == value &&
      !value.runes.any((r) => r < 32 || (r >= 127 && r <= 159)) &&
      !value.split('/').any((part) => part.toLowerCase().endsWith('.app'));

  static bool _inside(String root, String value) =>
      path.posix.equals(root.toLowerCase(), value.toLowerCase()) ||
      path.posix.isWithin(root.toLowerCase(), value.toLowerCase());
}

/// Selected original-byte metadata only, not a complete copy fingerprint.
final class ImportedCommitCopyFile {
  const ImportedCommitCopyFile._(
    this.path,
    this.mode,
    this.gitBlob,
    this.digest,
    this.byteLength,
  );
  final String path, mode, gitBlob, digest;
  final int byteLength;
  Map<String, Object> toJson() => {
    'path': path,
    'mode': mode,
    'git_blob': gitBlob,
    'sha256': digest,
    'byte_length': byteLength,
  };
}

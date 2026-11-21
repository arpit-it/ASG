// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'imported_commit_copy_record.dart';
import 'imported_commit_copy_request.dart';
import 'imported_commit_copy_recheck.dart';
import 'imported_commit_proposal_record.dart';
import 'imported_commit_proposal.dart';
import 'imported_commit_source_observation.dart';
import 'project_source_observation.dart';
import 'structured_proposal_json.dart';

/// Supplied isolated-output intent. The application must independently establish
/// current durable approval, fresh owned read, destination consent and admission.
final class ImportedCommitEditRequest {
  ImportedCommitEditRequest._(Map<String, Object> data, this.requestJson)
    : _data = Map.unmodifiable(data),
      digest = sha256.convert(utf8.encode(requestJson)).toString();
  static const byteLimit = 64 * 1024;
  final Map<String, Object> _data;
  final String requestJson, digest;
  String _string(String key) => _data[key]! as String;
  String get root => _string('root');
  String get python => _string('python');
  String get sourceCopy => _string('source_copy');
  String get destination => _string('destination');
  String get attemptId => _string('attempt_id');
  String get commit => _string('commit');
  String get tree => _string('tree');
  String get expectedSourceFingerprint =>
      _string('expected_source_fingerprint');
  String get selectedPath => _string('path');
  String get beforeHash => _string('before_sha256');
  String get afterHash => _string('after_sha256');
  String get replacement => _string('replacement');
  String get mode => _string('before_mode');
  bool get sourceVerified => false;
  bool get authorizesExecution => false;

  factory ImportedCommitEditRequest.create({
    required ImportedCommitCopyRecord copyHistory,
    required ImportedCommitProposalRecord proposal,
    required ImportedCommitCopyRecheckRequest reviewed,
    required ImportedCommitCopyRecheckObservation observation,
    required String python,
    required String destination,
    required String attemptId,
  }) {
    try {
      final history = ImportedCommitCopyRecord.decode(copyHistory.recordJson),
          saved = ImportedCommitProposalRecord.decode(proposal.encode());
      final rebuilt = ImportedCommitCopyRecheckRequest.create(
        history: history,
        python: python,
        recheckId: reviewed.recheckId,
      );
      final observed = ImportedCommitCopyRecheckObservation.fromJson(
        observation.recordJson,
        request: reviewed,
      );
      if (!rebuilt.matches(reviewed) ||
          observed.status != ImportedCommitCopyRecheckStatus.matching ||
          observed.observedFingerprint != reviewed.expectedFingerprint) {
        throw const FormatException();
      }
      final prepared = history.lastPrepared!,
          original = history.lastPrepared!.request,
          change = saved.proposal;
      if (original.historyDigest != saved.digest ||
          original.contextDigest != saved.context.digest ||
          original.planDigest != change.planDigest ||
          original.proposalDigest != change.digest ||
          original.commit != saved.context.commit ||
          original.tree != saved.context.tree ||
          original.manifestDigest != saved.context.manifestDigest ||
          original.manifestFiles != saved.context.manifestFiles) {
        throw const FormatException();
      }
      final source = change.source,
          selected = original.selectedFiles.singleWhere(
            (file) => file.path == source.source.path,
          );
      if (selected.mode != source.mode ||
          selected.gitBlob != source.gitBlob ||
          selected.digest != source.source.digest ||
          selected.byteLength != source.source.byteLength ||
          !preservesFormat(source.source.text, change.replacement) ||
          !ImportedCommitCopyRequest.validPath(destination) ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(attemptId) ||
          attemptId == '0' * 32 ||
          _inside(history.root, destination) ||
          _inside(path.posix.dirname(reviewed.copyPath), destination) ||
          _inside(destination, python)) {
        throw const FormatException();
      }
      final data = <String, Object>{
        'version': 1,
        'scope': 'imported-commit-edit-request',
        'root': history.root,
        'python': python,
        'source_copy': reviewed.copyPath,
        'destination': destination,
        'attempt_id': attemptId,
        'commit': original.commit,
        'tree': original.tree,
        'manifest_sha256': original.manifestDigest,
        'manifest_files': original.manifestFiles,
        'copy_history_sha256': history.digest,
        'copy_request_sha256': original.digest,
        'copy_receipt_sha256': sha256
            .convert(utf8.encode(prepared.observation!.recordJson))
            .toString(),
        'recheck_request_sha256': reviewed.digest,
        'recheck_observation_sha256': sha256
            .convert(utf8.encode(observed.recordJson))
            .toString(),
        'context_sha256': saved.context.digest,
        'plan_sha256': change.planDigest,
        'proposal_sha256': change.digest,
        'proposal_history_sha256': saved.digest,
        'expected_source_fingerprint': reviewed.expectedFingerprint,
        'path': selected.path,
        'before_mode': selected.mode,
        'before_git_blob': selected.gitBlob,
        'before_sha256': selected.digest,
        'before_byte_length': selected.byteLength,
        'replacement': change.replacement,
        'after_sha256': change.afterHash,
        'after_byte_length': change.afterByteLength,
      };
      final raw = jsonEncode(data);
      if (utf8.encode(raw).length > byteLimit) throw const FormatException();
      return ImportedCommitEditRequest.restore(raw);
    } catch (_) {
      throw const FormatException(
        'Isolated proposed-copy inputs changed or are unsupported.',
      );
    }
  }

  String get contextDigest => _string('context_sha256');
  String get planDigest => _string('plan_sha256');
  String get proposalDigest => _string('proposal_sha256');
  String get historyDigest => _string('proposal_history_sha256');
  String get copyHistoryDigest => _string('copy_history_sha256');
  String get proposalHistoryDigest => _string('proposal_history_sha256');
  String get recheckRequestDigest => _string('recheck_request_sha256');
  String get manifestDigest => _string('manifest_sha256');
  int get manifestFiles => _data['manifest_files']! as int;
  int get beforeByteLength => _data['before_byte_length']! as int;
  int get afterByteLength => _data['after_byte_length']! as int;
  static bool validPath(String value) =>
      ImportedCommitCopyRequest.validPath(value);
  bool matches(ImportedCommitEditRequest other) =>
      requestJson == other.requestJson;

  /// Supplied historical intent only. Admission must rebuild exact current data.
  factory ImportedCommitEditRequest.restore(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      final data = jsonDecode(raw);
      rejectDuplicateJsonMembers(raw);
      const keys = [
        'version',
        'scope',
        'root',
        'python',
        'source_copy',
        'destination',
        'attempt_id',
        'commit',
        'tree',
        'manifest_sha256',
        'manifest_files',
        'copy_history_sha256',
        'copy_request_sha256',
        'copy_receipt_sha256',
        'recheck_request_sha256',
        'recheck_observation_sha256',
        'context_sha256',
        'plan_sha256',
        'proposal_sha256',
        'proposal_history_sha256',
        'expected_source_fingerprint',
        'path',
        'before_mode',
        'before_git_blob',
        'before_sha256',
        'before_byte_length',
        'replacement',
        'after_sha256',
        'after_byte_length',
      ];
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'imported-commit-edit-request') {
        throw const FormatException();
      }
      const integers = {
        'version',
        'manifest_files',
        'before_byte_length',
        'after_byte_length',
      };
      if (keys.any(
        (key) =>
            integers.contains(key) ? data[key] is! int : data[key] is! String,
      )) {
        throw const FormatException();
      }
      String value(String key) => data[key] as String;
      final source = value('source_copy'), parent = path.posix.dirname(source);
      final bytes = utf8.encode(value('replacement'));
      if (![
            'root',
            'python',
            'source_copy',
            'destination',
          ].every((key) => ImportedCommitCopyRequest.validPath(value(key))) ||
          ![
            'commit',
            'tree',
            'before_git_blob',
          ].every((key) => ImportedCommitReadRequest.validCommit(value(key))) ||
          !keys
              .where(
                (key) =>
                    key.endsWith('_sha256') ||
                    key == 'expected_source_fingerprint',
              )
              .every((key) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value(key))) ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(value('attempt_id')) ||
          value('attempt_id') == '0' * 32 ||
          path.posix.basename(source) != 'source-${value('commit')}' ||
          !RegExp(r'^asg-self-candidate-[a-f0-9]{8}$')
              .hasMatch(path.posix.basename(parent)) ||
          !ProjectSourceObservation.validSelection([value('path')]) ||
          !{'100644', '100755'}.contains(value('before_mode')) ||
          data['manifest_files'] < 1 ||
          data['manifest_files'] > 2048 ||
          data['before_byte_length'] < 0 ||
          data['before_byte_length'] > 32768 ||
          !ImportedCommitProposal.validText(value('replacement')) ||
          data['after_byte_length'] != bytes.length ||
          value('after_sha256') != sha256.convert(bytes).toString() ||
          _inside(value('root'), source) ||
          _inside(value('root'), value('destination')) ||
          _inside(parent, value('destination')) ||
          _inside(value('root'), value('python')) ||
          _inside(path.posix.dirname(parent), value('python')) ||
          _inside(value('destination'), value('python'))) {
        throw const FormatException();
      }
      final canonical = <String, Object>{
        for (final key in keys) key: data[key] as Object,
      };
      if (jsonEncode(canonical) != raw) throw const FormatException();
      return ImportedCommitEditRequest._(canonical, raw);
    } catch (_) {
      throw const FormatException('Invalid isolated proposed-copy intent.');
    }
  }

  /// Preserve literal BOM presence and the exact supported leading legal header.
  /// Unrecognized legal-header placement refuses instead of rewriting its bytes.
  static bool preservesFormat(String before, String after) {
    final bom = before.startsWith('\ufeff');
    if (bom != after.startsWith('\ufeff')) return false;
    final source = bom ? before.substring(1) : before,
        replacement = bom ? after.substring(1) : after;
    bool legal(String text) => RegExp(
      r'SPDX-License-Identifier:|copyright',
      caseSensitive: false,
    ).hasMatch(text);
    if (!legal(source)) return true;
    String? header = RegExp(r'^(?://[^\r\n]*(?:\r\n|\r|\n))+')
        .firstMatch(source)
        ?.group(0);
    if (header == null && source.startsWith('/*')) {
      final end = source.indexOf('*/', 2);
      if (end >= 0) {
        var length = end + 2;
        if (source.startsWith('\r\n', length)) {
          length += 2;
        } else if (source.startsWith('\n', length) ||
            source.startsWith('\r', length)) {
          length++;
        }
        header = source.substring(0, length);
      }
    }
    return header != null && legal(header) && replacement.startsWith(header);
  }

  static bool _inside(String root, String value) =>
      path.posix.equals(root.toLowerCase(), value.toLowerCase()) ||
      path.posix.isWithin(root.toLowerCase(), value.toLowerCase());
}

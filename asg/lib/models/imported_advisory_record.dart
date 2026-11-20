// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'imported_advisory_request.dart';
import 'local_model_config.dart';
import 'structured_proposal_json.dart';

/// Historical advisory text and app-observed identity, never plan approval.
final class ImportedAdvisoryRecord {
  ImportedAdvisoryRecord._(
    this.root,
    this.question,
    this.contextDigest,
    this.requestDigest,
    this.endpoint,
    this.model,
    this.outputTokens,
    this.responseModel,
    this.answer,
    this.recordedAt,
  );
  static const answerLimit = 12000, recordByteLimit = 128 * 1024;
  final String root,
      question,
      contextDigest,
      requestDigest,
      endpoint,
      model,
      responseModel,
      answer;
  final int outputTokens;
  final DateTime recordedAt;

  factory ImportedAdvisoryRecord.complete(
    ImportedAdvisoryRequest request,
    String answer,
    String responseModel,
  ) => ImportedAdvisoryRecord.decode(
    jsonEncode({
      'version': 1,
      'root':
          (jsonDecode(request.context.recordJson)['metadata'] as Map)['root'],
      'question': request.question,
      'contextDigest': request.contextDigest,
      'requestDigest': request.digest,
      'endpoint': request.config.endpoint.toString(),
      'model': request.config.model,
      'outputTokens': request.config.chatOutputTokens,
      'responseModel': responseModel,
      'answer': answer,
      'recordedAt': DateTime.now().toUtc().toIso8601String(),
    }),
  );

  factory ImportedAdvisoryRecord.decode(String raw) {
    try {
      if (utf8.encode(raw).length > recordByteLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final data = jsonDecode(raw);
      const keys = {
        'version',
        'root',
        'question',
        'contextDigest',
        'requestDigest',
        'endpoint',
        'model',
        'outputTokens',
        'responseModel',
        'answer',
        'recordedAt',
      };
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['outputTokens'] is! int ||
          keys
              .difference({'version', 'outputTokens'})
              .any((k) => data[k] is! String)) {
        throw const FormatException();
      }
      final root = data['root'] as String,
          question = data['question'] as String,
          answer = data['answer'] as String;
      final config = LocalModelConfig(
        baseUrl: data['endpoint'] as String,
        model: data['model'] as String,
        chatOutputTokens: data['outputTokens'] as int,
      );
      config.validateChatLimit();
      if (config.endpoint.toString() != data['endpoint'] ||
          data['responseModel'] != config.model ||
          root.isEmpty ||
          utf8.encode(root).length > 4096 ||
          root.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
          question.trim().isEmpty ||
          question != question.trim() ||
          question.length > ImportedAdvisoryRequest.questionLimit ||
          question.contains('\u0000') ||
          answer.trim().isEmpty ||
          answer.length > answerLimit ||
          answer.contains('\u0000') ||
          !RegExp(r'^[0-9a-f]{64}$')
              .hasMatch(data['contextDigest'] as String) ||
          !RegExp(r'^[0-9a-f]{64}$')
              .hasMatch(data['requestDigest'] as String)) {
        throw const FormatException();
      }
      final at = DateTime.tryParse(data['recordedAt'] as String);
      if (at == null || !at.isUtc) throw const FormatException();
      return ImportedAdvisoryRecord._(
        root,
        question,
        data['contextDigest'] as String,
        data['requestDigest'] as String,
        config.endpoint.toString(),
        config.model,
        config.chatOutputTokens,
        data['responseModel'] as String,
        answer,
        at,
      );
    } catch (_) {
      throw const FormatException(
        'Saved imported advisory answer is unreadable.',
      );
    }
  }

  String encode() => jsonEncode({
    'version': 1,
    'root': root,
    'question': question,
    'contextDigest': contextDigest,
    'requestDigest': requestDigest,
    'endpoint': endpoint,
    'model': model,
    'outputTokens': outputTokens,
    'responseModel': responseModel,
    'answer': answer,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
  });
}

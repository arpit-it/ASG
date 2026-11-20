// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_plan.dart';
import 'imported_source_context.dart';
import 'imported_source_proposal.dart';
import 'structured_proposal_json.dart';

/// Historical review data only. Saving or restoring grants no current approval.
final class ImportedSourceProposalRecord {
  ImportedSourceProposalRecord._(
    this.context,
    this.plan,
    this.proposal,
    this.recordedAt,
    this.recordJson,
    this.digest,
  );
  static const byteLimit = 256 * 1024;
  final ImportedSourceContext context;
  final ImportedPlan plan;
  final ImportedSourceProposal proposal;
  final DateTime recordedAt;
  final String recordJson, digest;
  String get root => proposal.root;
  bool get sourceVerified => false;
  String encode() => recordJson;

  factory ImportedSourceProposalRecord.create({
    required ImportedSourceContext context,
    required ImportedPlan plan,
    required ImportedSourceProposal proposal,
    required DateTime recordedAt,
  }) {
    if (context.recordJson != plan.context) {
      throw const FormatException('Saved source proposal is invalid.');
    }
    return ImportedSourceProposalRecord.decode(
      jsonEncode({
        'version': 1,
        'scope': 'historical-imported-source-proposal',
        'root': proposal.root,
        'plan': plan.toJson(),
        'proposal': proposal.recordJson,
        'recordedAt': recordedAt.toUtc().toIso8601String(),
      }),
    );
  }

  factory ImportedSourceProposalRecord.decode(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      final data = jsonDecode(raw);
      rejectDuplicateJsonMembers(raw);
      const keys = {
        'version',
        'scope',
        'root',
        'plan',
        'proposal',
        'recordedAt',
      };
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'historical-imported-source-proposal' ||
          data['root'] is! String ||
          data['proposal'] is! String ||
          data['recordedAt'] is! String) {
        throw const FormatException();
      }
      final planData = data['plan'] as Map<String, dynamic>;
      const planKeys = {'text', 'context', 'approved', 'recordedAt'};
      if (planData.length != planKeys.length ||
          !planData.keys.toSet().containsAll(planKeys)) {
        throw const FormatException();
      }
      final plan = ImportedPlan.fromJson(planData);
      // JSON permits escaped unpaired UTF-16; do not silently encode replacement bytes.
      var roundTrip = utf8.decode(utf8.encode(plan.text));
      if (plan.text.startsWith('\ufeff')) roundTrip = '\ufeff$roundTrip';
      if (roundTrip != plan.text ||
          jsonEncode(plan.toJson()) != jsonEncode(planData)) {
        throw const FormatException();
      }
      final context = ImportedSourceContext.restore(plan.context);
      final proposalRaw = data['proposal'] as String;
      if (proposalRaw.length > ImportedSourceProposal.recordByteLimit ||
          utf8.encode(proposalRaw).length >
              ImportedSourceProposal.recordByteLimit) {
        throw const FormatException();
      }
      final proposed = jsonDecode(proposalRaw) as Map<String, dynamic>;
      rejectDuplicateJsonMembers(proposalRaw);
      final proposal = ImportedSourceProposal.create(
        context: context,
        plan: plan,
        path: proposed['path'] as String,
        replacement: proposed['replacement'] as String,
      );
      if (proposal.recordJson != proposalRaw || proposal.root != data['root']) {
        throw const FormatException();
      }
      final time = DateTime.parse(data['recordedAt'] as String).toUtc();
      final canonical = jsonEncode({
        'version': 1,
        'scope': 'historical-imported-source-proposal',
        'root': proposal.root,
        'plan': plan.toJson(),
        'proposal': proposal.recordJson,
        'recordedAt': time.toIso8601String(),
      });
      if (canonical != raw) throw const FormatException();
      return ImportedSourceProposalRecord._(
        context,
        plan,
        proposal,
        time,
        raw,
        sha256.convert(utf8.encode(raw)).toString(),
      );
    } catch (_) {
      throw const FormatException('Saved source proposal is invalid.');
    }
  }
}

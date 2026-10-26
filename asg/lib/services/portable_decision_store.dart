import 'dart:convert';

import '../models/portable_project_archive.dart';
import '../models/structured_proposal_json.dart';
import '../models/plan_approval.dart';
import 'record_storage.dart';

/// Imported history never writes or supplies execution consent.
class PortableDecisionStore {
  PortableDecisionStore(this.records);
  final RecordStorage records;
  static String key(String id) => 'studio.historicalDecision.v1.$id';
  static PortablePlanDecision decode(String raw) {
    rejectDuplicateJsonMembers(raw);
    return PortablePlanDecision.fromJson(jsonDecode(raw));
  }

  PortablePlanDecision? load(String id) {
    // A subsequent local decision supersedes imported history in new exports.
    final localRaw = records.getString('studio.planApproval.v1.$id');
    PlanApproval? local;
    if (localRaw != null) {
      final value = jsonDecode(localRaw);
      const fields = [
        'messageIndex',
        'content',
        'context',
        'approved',
        'recordedAt',
      ];
      if (value is! Map<String, dynamic> ||
          value.length != fields.length ||
          fields.any((key) => !value.containsKey(key))) {
        throw const FormatException('Unsupported saved decision fields.');
      }
      local = PlanApproval.fromJson(value);
    }
    if (local != null) {
      return PortablePlanDecision(
        content: local.content,
        approved: local.approved,
        recordedAt: local.recordedAt,
      );
    }
    final raw = records.getString(key(id));
    return raw == null ? null : decode(raw);
  }
}

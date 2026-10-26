import 'dart:convert';

import '../models/portable_project_archive.dart';
import '../models/structured_proposal_json.dart';
import 'plan_approval_store.dart';
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
    final local = PlanApprovalStore(records).load(id);
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

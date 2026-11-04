// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../model_request_provenance.dart';
import '../structured_proposal_json.dart';
import 'html_source_proposal.dart';

/// A retained review artifact, never an approval, check result or live source.
class HtmlSourceDraft {
  const HtmlSourceDraft({
    required this.projectId,
    required this.contextDigest,
    required this.proposal,
    required this.provenance,
    required this.locallyEdited,
  });
  final String projectId, contextDigest;
  final HtmlSourceProposal proposal;
  final ModelRequestProvenance provenance;
  final bool locallyEdited;

  factory HtmlSourceDraft.decode(String value) {
    if (value.length > 512000 || utf8.encode(value).length > 512000) {
      throw const FormatException('Saved HTML draft is too large.');
    }
    final raw = jsonDecode(value);
    rejectDuplicateJsonMembers(value);
    if (raw is! Map<String, dynamic> ||
        raw.length != 6 ||
        raw['version'] != 1 ||
        raw['version'] is! int ||
        raw['projectId'] is! String ||
        (raw['projectId'] as String).isEmpty ||
        (raw['projectId'] as String).length > 512 ||
        raw['contextDigest'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['contextDigest'] as String) ||
        raw['locallyEdited'] is! bool) {
      throw const FormatException('Invalid saved HTML draft.');
    }
    final provenance = ModelRequestProvenance.fromJson(raw['provenance']);
    if (provenance.outputTokens != ModelRequestProvenance.sourceOutputTokens) {
      throw const FormatException('Invalid HTML source request provenance.');
    }
    return HtmlSourceDraft(
      projectId: raw['projectId'] as String,
      contextDigest: raw['contextDigest'] as String,
      proposal: HtmlSourceProposal.decode(jsonEncode(raw['proposal'])),
      provenance: provenance,
      locallyEdited: raw['locallyEdited'] as bool,
    );
  }

  String encode() {
    final value = jsonEncode({
      'version': 1,
      'projectId': projectId,
      'contextDigest': contextDigest,
      'proposal': {'summary': proposal.summary, 'files': proposal.files},
      'provenance': provenance.toJson(),
      'locallyEdited': locallyEdited,
    });
    HtmlSourceDraft.decode(value);
    return value;
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'structured_proposal_json.dart';

/// One harmless prompt-format observation, never general schema capability.
class ModelFormatProbe {
  static const prompt =
      'Return exactly one JSON object with one member: {"asg_probe":"ok"}. '
      'Do not include markdown, explanation or additional members.';

  static bool accepts(String text) {
    try {
      final value = jsonDecode(text);
      rejectDuplicateJsonMembers(text);
      return value is Map<String, dynamic> &&
          value.length == 1 &&
          value['asg_probe'] == 'ok';
    } on FormatException {
      return false;
    }
  }

  static const guidance =
      'JSON format test sends a small fixed prompt to the draft connection. '
      'It observes one completed response only; it does not enable JSON mode, '
      'verify loaded weights, tool calling, arbitrary schemas or context capacity. '
      'Results are temporary and are not saved as model capabilities.';
}

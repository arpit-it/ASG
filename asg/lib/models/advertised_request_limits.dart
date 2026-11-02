// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Untrusted server assertions, separate from user notes and measured capacity.
class AdvertisedRequestLimits {
  const AdvertisedRequestLimits._(this.input, this.output, this.context);

  final int input;
  final int output;
  final int? context;

  factory AdvertisedRequestLimits.fromJson(Object? value) {
    const invalid = FormatException('Invalid advertised request limits.');
    if (value is! Map<String, dynamic> ||
        value['schema_version'] != 1 ||
        value['schema_version'] is! int ||
        value.length != 4 ||
        !value.containsKey('checkpoint_context_tokens')) {
      throw invalid;
    }
    bool valid(Object? count) =>
        count is int && count > 0 && count <= 9007199254740991;
    final input = value['max_input_tokens'];
    final output = value['max_output_tokens'];
    final context = value['checkpoint_context_tokens'];
    if (!valid(input) ||
        !valid(output) ||
        (context != null && !valid(context))) {
      throw invalid;
    }
    return AdvertisedRequestLimits._(
      input as int,
      output as int,
      context as int?,
    );
  }

  /// Compare only the reserved output. The actual prompt has not been counted.
  /// Server assertions can reveal a conflict but cannot establish compatibility.
  String describeDraftOutput(int tokens) {
    if (tokens < 1) {
      throw const FormatException('Invalid draft output budget.');
    }
    final outputComparison = tokens > output
        ? 'exceeds the server-declared output ceiling of $output tokens'
        : 'does not exceed the server-declared output ceiling of $output tokens';
    final contextComparison = context == null
        ? 'Total context is unknown.'
        : tokens > context!
        ? 'The output reservation alone exceeds the checkpoint-declared total context of $context tokens.'
        : tokens == context
        ? 'The output reservation uses the entire checkpoint-declared total context of $context tokens, leaving no room for a prompt.'
        : 'The output reservation alone is below the checkpoint-declared total context of $context tokens.';
    return 'Draft chat output budget: $tokens tokens; $outputComparison. '
        '$contextComparison '
        'Prompt tokens have not been counted; prompt-plus-output fit and usable model capacity remain unverified. '
        'This comparison does not change budgets or authorize a request.';
  }

  String get description =>
      'Server-declared request ceilings: $input input tokens, $output output tokens. '
      '${context == null ? 'Checkpoint total context is unknown.' : 'Checkpoint-declared total context: $context tokens; prompt plus full requested output must fit.'} '
      'These limits do not verify usable capacity, loaded identity or inference. '
      'Requests and settings are unchanged.';
}

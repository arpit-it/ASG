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

  String get description =>
      'Server-declared request ceilings: $input input tokens, $output output tokens. '
      '${context == null ? 'Checkpoint total context is unknown.' : 'Checkpoint-declared total context: $context tokens; prompt plus full requested output must fit.'} '
      'These limits do not verify usable capacity, loaded identity or inference. '
      'Requests and settings are unchanged.';
}

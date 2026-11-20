// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'live_model_config.dart' show liveModelId;

/// Validates bridge assertions for the opt-in initial source request only.
/// This neither authenticates weights nor proves a later response's model ID.
void requireInitialRequestLiveReadiness(Object? health, Object? inventory) {
  if (health is! Map<String, Object?> ||
      health['status'] != 'ready' ||
      health['phase'] != 'idle' ||
      health['backend'] != 'mlx' ||
      health['device'] != 'metal' ||
      health['model'] != liveModelId ||
      health['streaming'] != true) {
    throw StateError('Initial-request live runtime is not ready on MLX/Metal.');
  }
  if (inventory is! Map<String, Object?>) {
    throw StateError('Initial-request live model inventory is invalid.');
  }
  final data = inventory['data'];
  if (data is! List || data.length != 1) {
    throw StateError('Expected the single configured live model.');
  }
  final entry = data.single;
  if (entry is! Map<String, Object?> || entry['id'] != liveModelId) {
    throw StateError('Initial-request live model identity does not match.');
  }
  final limits = entry['asg_request_limits'];
  if (limits is! Map<String, Object?> ||
      limits['schema_version'] is! int ||
      limits['schema_version'] != 1 ||
      limits['max_input_tokens'] is! int ||
      limits['max_input_tokens'] != 4096 ||
      limits['max_output_tokens'] is! int ||
      limits['max_output_tokens'] != 4096) {
    throw StateError('Initial-request live source budget is not verified.');
  }
}

/// Reads only the owner's fixed bridge routes. No redirect, retry or inference.
/// The client created here is always closed, including timeout/parser failures.
Future<void> checkInitialRequestLiveReadiness({
  http.Client Function()? createClient,
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
  final client = (createClient ?? http.Client.new)();
  Future<Object?> read(String path) async {
    final request = http.Request('GET', Uri.parse('http://127.0.0.1:8765$path'))
      ..followRedirects = false;
    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw StateError('Live readiness endpoint refused the check.');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > 16384) {
        throw StateError(
          'Live readiness reply exceeds the bounded metadata size.',
        );
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  try {
    final health = await read('/health').timeout(timeout);
    final inventory = await read('/v1/models').timeout(timeout);
    requireInitialRequestLiveReadiness(health, inventory);
  } finally {
    client.close();
  }
}

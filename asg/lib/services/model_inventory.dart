// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/local_model_config.dart';

/// Read-only server assertion. Inventory membership never verifies loaded weights.
class ModelInventory {
  static const timeout = Duration(seconds: 3);
  static const maxBytes = 65536;

  static Future<String> inspect(LocalModelConfig config) async {
    final client = http.Client();
    try {
      return await check(config, client: client);
    } finally {
      client.close();
    }
  }

  static Future<String> check(
    LocalModelConfig config, {
    required http.Client client,
  }) async {
    try {
      final base = config.endpoint;
      if (config.model.length > 256) throw const FormatException();
      return await (() async {
        final request = http.Request('GET', base.resolve('models'))
          ..followRedirects = false;
        final response = await client.send(request);
        if (response.statusCode != 200) {
          return 'Model inventory unavailable. Check the local server supports the models endpoint; no model was tested.';
        }
        if ((response.contentLength ?? 0) > maxBytes) {
          throw const FormatException();
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const FormatException();
          }
          bytes.addAll(chunk);
        }
        final body = jsonDecode(utf8.decode(bytes));
        if (body is! Map<String, dynamic> ||
            body['data'] is! List ||
            (body['data'] as List).length > 1000) {
          throw const FormatException();
        }
        final ids = <String>{};
        for (final entry in body['data'] as List) {
          if (entry is! Map<String, dynamic>) throw const FormatException();
          final id = entry['id'];
          if (id is! String ||
              id.isEmpty ||
              id.length > 256 ||
              id.trim() != id ||
              id.runes.any((r) => r < 32 || r == 127) ||
              !ids.add(id)) {
            throw const FormatException();
          }
        }
        return ids.contains(config.model)
            ? 'Server advertises the exact draft model ID. This is a server assertion; loaded weights, context limits, structured output and inference remain unverified.'
            : 'Server does not advertise the exact draft model ID. Check the ID and runtime before testing. Settings are unchanged.';
      })().timeout(timeout);
    } on TimeoutException {
      return 'Model inventory timed out after 3 seconds. Check the local server and retry.';
    } on FormatException {
      return 'Model inventory or draft settings are invalid or exceed limits. Check the local URL, exact model ID and server response; no model was tested.';
    } catch (_) {
      return 'Model inventory is not reachable. Check the local server and retry; no model was tested.';
    }
  }
}

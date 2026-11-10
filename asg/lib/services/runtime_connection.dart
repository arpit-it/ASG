// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/local_model_config.dart';
import '../models/runtime_setup.dart';

class RuntimeConnection {
  RuntimeConnection({http.Client? client}) : _client = client ?? http.Client();
  static const _maxHealthBytes = 64 * 1024;
  final http.Client _client;
  Future<RuntimeHealth> check(LocalModelConfig config) async {
    final abort = Completer<void>();
    StreamIterator<List<int>>? responseBody;
    try {
      final base = config.endpoint;
      final request = http.AbortableRequest(
        'GET',
        base.replace(path: '/health'),
        abortTrigger: abort.future,
      )..followRedirects = false;

      Future<http.Response?> readResponse() async {
        final response = await _client.send(request);
        final oversized =
            response.statusCode == 200 &&
            (response.contentLength ?? 0) > _maxHealthBytes;
        if (abort.isCompleted || response.statusCode != 200 || oversized) {
          // Release the response without buffering an error body or starting
          // a late read when an injected client ignored request cancellation.
          _cancelResponse(response.stream.listen(null).cancel());
          if (oversized) {
            throw const FormatException('Health response too large');
          }
          return null;
        }

        final iterator = StreamIterator(response.stream);
        responseBody = iterator;
        final bytes = BytesBuilder();
        while (await iterator.moveNext()) {
          final chunk = iterator.current;
          if (chunk.length > _maxHealthBytes - bytes.length) {
            throw const FormatException('Health response too large');
          }
          bytes.add(chunk);
        }
        return http.Response.bytes(
          bytes.takeBytes(),
          response.statusCode,
          headers: response.headers,
        );
      }

      final response = await readResponse().timeout(const Duration(seconds: 3));
      if (response == null) {
        return const RuntimeHealth(
          ready: false,
          detail: 'Runtime health endpoint did not respond successfully. Check the local server and connection URL.',
        );
      }
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic> ||
          !['ready', 'loading', 'error'].contains(data['status']) ||
          (data['model'] != null && data['model'] is! String) ||
          (data['model_path'] != null && data['model_path'] is! String)) {
        throw const FormatException('Invalid health response');
      }
      // Health text is locally authored. Server fields can contain private data.
      // Identity is retained only for matching the selected model during startup.
      final ready = data['status'] == 'ready';
      final phase = switch (data['phase']) {
        'idle' => 'No model request active.',
        'thinking' => 'A model request is processing.',
        'writing' => 'A model response is streaming.',
        _ => 'Active request state is unavailable.',
      };
      return RuntimeHealth(
        ready: ready,
        idle: ready && data['phase'] == 'idle',
        detail: switch (data['status']) {
          'ready' => 'Runtime reports ready. $phase',
          'loading' =>
            'Runtime reports model loading. Wait and refresh status.',
          _ => 'Runtime reports a failure. Check the runtime environment and retry.',
        },
        model: data['model'] as String?,
        modelPath: data['model_path'] as String?,
        loadedDevice: ready
            ? LoadedRuntimeDevice.reported(data['backend'], data['device'])
            : null,
      );
    } on TimeoutException {
      return const RuntimeHealth(
        ready: false,
        detail: 'Runtime health check timed out after 3 seconds. Check the local server and retry.',
      );
    } on FormatException {
      return const RuntimeHealth(
        ready: false,
        detail: 'Runtime health response or connection settings are invalid. Check the local server, URL and model ID.',
      );
    } catch (_) {
      return const RuntimeHealth(
        ready: false,
        detail: 'Runtime is not reachable. Start it on the Mac or check the connection URL.',
      );
    } finally {
      final iterator = responseBody;
      if (iterator != null) _cancelResponse(iterator.cancel());
      abort.complete();
    }
  }

  void close() => _client.close();
}

void _cancelResponse(Future<void> cancellation) {
  // Cleanup is best-effort and must not delay the result or surface transport
  // details. The request abort also covers supported clients awaiting headers.
  unawaited(cancellation.catchError((Object _) {}));
}

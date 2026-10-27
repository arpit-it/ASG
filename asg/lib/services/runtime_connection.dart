import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/local_model_config.dart';
import '../models/runtime_setup.dart';

class RuntimeConnection {
  RuntimeConnection({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  Future<RuntimeHealth> check(LocalModelConfig config) async {
    try {
      final base = config.endpoint;
      final response = await _client
          .get(base.replace(path: '/health'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) {
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
        detail: switch (data['status']) {
          'ready' => 'Runtime reports ready. $phase',
          'loading' =>
            'Runtime reports model loading. Wait and refresh status.',
          _ => 'Runtime reports a failure. Check the runtime environment and retry.',
        },
        model: data['model'] as String?,
        modelPath: data['model_path'] as String?,
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
    }
  }

  void close() => _client.close();
}

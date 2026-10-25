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
          detail: 'Runtime health endpoint did not respond successfully.',
        );
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return RuntimeHealth(
        ready: data['status'] == 'ready',
        detail:
            '${data['backend'] is String ? data['backend'] : 'Local'} inference · ${data['phase'] is String ? data['phase'] : 'ready'}',
        model: data['model'] as String?,
        modelPath: data['model_path'] as String?,
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

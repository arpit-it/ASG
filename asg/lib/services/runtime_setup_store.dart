import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/runtime_setup.dart';

class RuntimeSetupStore {
  RuntimeSetupStore(this.preferences);
  final SharedPreferences preferences;
  RuntimeSetup load() {
    final raw = preferences.getString('studio.runtimeSetup.v1');
    return raw == null
        ? const RuntimeSetup()
        : RuntimeSetup.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(RuntimeSetup setup) async {
    if (!await preferences.setString(
      'studio.runtimeSetup.v1',
      jsonEncode(setup.toJson()),
    )) {
      throw StateError('Runtime settings could not be saved.');
    }
  }
}

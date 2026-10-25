import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'record_storage.dart';

import '../models/runtime_setup.dart';

class RuntimeSetupStore {
  RuntimeSetupStore(this.records);
  RuntimeSetupStore.fromPreferences(SharedPreferences preferences)
    : this(PreferenceRecords(preferences));
  final RecordStorage records;
  RuntimeSetup load() {
    final raw = records.getString('studio.runtimeSetup.v1');
    return raw == null
        ? const RuntimeSetup()
        : RuntimeSetup.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(RuntimeSetup setup) async {
    if (!await records.setString(
      'studio.runtimeSetup.v1',
      jsonEncode(setup.toJson()),
    )) {
      throw StateError('Runtime settings could not be saved.');
    }
  }
}

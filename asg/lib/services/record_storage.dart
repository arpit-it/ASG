import 'package:shared_preferences/shared_preferences.dart';

/// Synchronous session snapshot; writes complete only after durable commit.
abstract interface class RecordStorage {
  String? getString(String key);
  Future<bool> setString(String key, String value);
}

/// Legacy adapter for migration validation and existing injected repositories.
/// Production bootstrap uses StudioDatabase instead.
class PreferenceRecords implements RecordStorage {
  PreferenceRecords(this.preferences);
  final SharedPreferences preferences;
  @override
  String? getString(String key) => preferences.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      preferences.setString(key, value);
}

/// Atomic conditional publication, including a durable previous-working pointer.
abstract interface class ConditionalRecordStorage implements RecordStorage {
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  });
}

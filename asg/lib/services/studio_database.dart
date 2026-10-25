import 'dart:convert';

import 'package:sembast/sembast.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/requirements_board.dart';
import '../models/project.dart';
import '../models/plan_approval.dart';
import '../models/source_generation.dart';
import 'application_store.dart';
import 'conversation_store.dart';
import 'database_factory.dart';
import 'model_settings_store.dart';
import 'record_storage.dart';
import 'runtime_setup_store.dart';
import 'studio_store.dart';

/// One database/session per application isolate. Original preferences are retained.
class StudioDatabase implements RecordStorage {
  StudioDatabase._(this.database, this._values, this._recordErrors);
  final Database database;
  final Map<String, String> _values;
  final Map<String, FormatException> _recordErrors;
  static final _records = StoreRef<String, String>('records');
  static final _metadata = StoreRef<String, int>('metadata');
  static Future<StudioDatabase>? _opening;

  static Future<StudioDatabase> open() => _opening ??= _openDefault();
  static Future<StudioDatabase> _openDefault() async {
    Database? db;
    try {
      db = await openStudioDatabase();
      return await migrate(db, await SharedPreferences.getInstance());
    } catch (_) {
      await db?.close();
      _opening = null;
      rethrow;
    }
  }

  /// Validation precedes a single transaction containing all records + marker.
  /// Existing DB values win on retries; no preference is deleted or rewritten.
  static Future<StudioDatabase> migrate(
    Database db,
    SharedPreferences legacy, {
    Future<void> Function()? beforeCommit,
  }) async {
    await db.transaction((txn) async {
      final marker = await _metadata.record('preferencesMigration').get(txn);
      if (marker != null && marker != 1) {
        throw const FormatException('Unsupported database migration version.');
      }
      if (marker == null) {
        final pending = <String, String>{};
        for (final key in legacy.getKeys().where(_isStudioKey)) {
          final value = legacy.get(key);
          if (value is! String) {
            throw FormatException('Invalid legacy record: $key');
          }
          validate(key, value);
          pending[key] = value;
        }
        for (final entry in pending.entries) {
          final record = _records.record(entry.key);
          if (await record.get(txn) == null) await record.put(txn, entry.value);
        }
        for (final record in await _records.find(txn)) {
          validate(record.key, record.value);
        }
        await _metadata.record('preferencesMigration').put(txn, 1);
        await beforeCommit?.call();
      }
    });
    final values = <String, String>{};
    final errors = <String, FormatException>{};
    for (final record in await _records.find(db)) {
      try {
        validate(record.key, record.value);
      } catch (_) {
        if (!record.key.startsWith('studio.application.v1.') &&
            !record.key.startsWith('studio.generation.v1.') &&
            !record.key.startsWith('studio.requirements.v1.') &&
            !record.key.startsWith('studio.planApproval.v1.')) {
          rethrow;
        }
        // Preserve unreadable project content verbatim. Its repository will
        // surface this error on access, without blocking unrelated projects.
        errors[record.key] = FormatException(
          'Saved project record is unreadable: ${record.key}',
        );
      }
      values[record.key] = record.value;
    }
    return StudioDatabase._(db, values, errors);
  }

  static bool _isStudioKey(String key) =>
      const [
        'studio.projects.v1',
        'studio.localModel.v1',
        'studio.runtimeSetup.v1',
        'studio.lastProject.v1',
      ].contains(key) ||
      key.startsWith('studio.chat.v1.') ||
      key.startsWith('studio.requirements.v1.') ||
      key.startsWith('studio.planApproval.v1.') ||
      key.startsWith('studio.application.v1.');

  static void validate(String key, String value) {
    if (key == 'studio.lastProject.v1') return;
    final decoded = jsonDecode(value);
    final source = _SingleRecord(key, value);
    if (key == 'studio.projects.v1') {
      StudioStore(source).load();
    } else if (key == 'studio.localModel.v1') {
      ModelSettingsStore(source).load().endpoint;
    } else if (key == 'studio.runtimeSetup.v1') {
      RuntimeSetupStore(source).load();
    } else if (key.startsWith('studio.chat.v1.')) {
      ConversationStore(source).load(key.substring('studio.chat.v1.'.length));
    } else if (key.startsWith('studio.application.v1.')) {
      ApplicationStore(source).load(
        StudioProject(
          id: key.substring('studio.application.v1.'.length),
          name: 'Migration',
          description: '',
          type: 'Flutter',
          platforms: const [],
          location: '',
        ),
      );
      if (decoded is! Map ||
          decoded['revision'] is! int ||
          (decoded['revision'] as int) < 1) {
        throw const FormatException('Invalid saved application revision.');
      }
    } else if (key.startsWith('studio.requirements.v1.')) {
      RequirementsBoard.fromJson(decoded as Map<String, dynamic>);
    } else if (key.startsWith('studio.planApproval.v1.')) {
      PlanApproval.fromJson(decoded as Map<String, dynamic>);
    } else if (key.startsWith('studio.generation.v1.')) {
      GeneratedProject.fromJson(decoded as Map<String, dynamic>);
    } else {
      throw FormatException('Unsupported database record: $key');
    }
  }

  @override
  String? getString(String key) {
    final error = _recordErrors[key];
    if (error != null) throw error;
    return _values[key];
  }

  @override
  Future<bool> setString(String key, String value) async {
    validate(key, value);
    await database.transaction((txn) => _records.record(key).put(txn, value));
    _values[key] = value;
    _recordErrors.remove(key);
    return true;
  }
}

class _SingleRecord implements RecordStorage {
  _SingleRecord(this.key, this.value);
  final String key, value;
  @override
  String? getString(String key) => key == this.key ? value : null;
  @override
  Future<bool> setString(String key, String value) =>
      throw UnsupportedError('Read only');
}

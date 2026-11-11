// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/local_model.dart';
import 'package:asg/services/record_storage.dart';

const liveModelId = 'Qwen3.8-27B-4bit';

Future<void> selectLiveModel(RecordStorage records) =>
    ModelSettingsStore(records).save(
      const LocalModelConfig(
        baseUrl: 'http://127.0.0.1:8765/v1',
        model: liveModelId,
      ),
    );

class LiveResponseModelProvider extends LocalModelProvider {
  LiveResponseModelProvider(
    super.config, {
    required super.maxTokens,
    super.idleTimeout,
    super.totalTimeout,
  });

  String? responseModelBeforeCleanup;

  @override
  Future<void> cancel() async {
    responseModelBeforeCleanup ??= completedResponseModel;
    await super.cancel();
  }
}

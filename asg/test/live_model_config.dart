// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/record_storage.dart';

Future<void> selectLiveModel(RecordStorage records) =>
    ModelSettingsStore(records).save(
      const LocalModelConfig(
        baseUrl: 'http://127.0.0.1:8765/v1',
        model: 'Qwen3.8-27B-4bit',
      ),
    );

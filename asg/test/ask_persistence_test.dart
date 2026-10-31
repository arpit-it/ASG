// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';

import 'ask_storage_cases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Ask real disk database survives two reopens and corrupt-record isolation',
    () async {
      final dir = await Directory.systemTemp.createTemp('asg-ask-storage-');
      try {
        await verifyAskStorage(databaseFactoryIo, '${dir.path}/ask.db');
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}

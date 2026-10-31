// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast_web/sembast_web.dart';

import 'ask_storage_cases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Ask actual Chrome IndexedDB survives two reopens and corrupt-record isolation', () async {
    await verifyAskStorage(
      databaseFactoryWeb,
      'asg-ask-${DateTime.now().microsecondsSinceEpoch}',
    );
  });
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'MVC boundaries keep external IO out of views and UI out of controllers',
    () {
      for (final file in Directory(
        'lib/views',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        for (final forbidden in [
          'package:shared_preferences/',
          'package:sembast',
          'package:http/',
          "import 'dart:io'",
          "import 'dart:convert'",
          'LocalModelProvider(',
          'jsonDecode(',
          'setString(',
        ]) {
          expect(
            source.contains(forbidden),
            false,
            reason:
                '${file.path} must delegate $forbidden to controllers/services',
          );
        }
      }
      for (final file in Directory(
        'lib/controllers',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        expect(
          file.readAsStringSync(),
          isNot(contains('package:flutter/material.dart')),
          reason: '${file.path} must not depend on widgets',
        );
        expect(
          file.readAsStringSync(),
          isNot(contains('BuildContext')),
          reason: '${file.path} must not navigate or display UI',
        );
      }
      for (final file in Directory(
        'lib/models',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        expect(source, isNot(contains('../services/')));
        expect(source, isNot(contains('package:flutter/')));
      }
    },
  );
}

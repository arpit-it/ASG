// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/project_details_controller.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/project_details_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'project_details_test.dart' show Records, original, appKey, projectKey;

const privateDetail = 'PRIVATE_PROMPT token=secret /private/workspace';

class PrivateFailureRecords extends Records {
  String? throwKey;
  Completer<void>? failureGate;

  @override
  Future<bool> setString(String key, String value) async {
    if (key == throwKey) {
      if (failureGate != null) await failureGate!.future;
      throw const FormatException(privateDetail, privateDetail);
    }
    return super.setString(key, value);
  }
}

void main() {
  for (final key in [appKey, projectKey]) {
    test('private $key write failure preserves state and explicit retry', () async {
      final records = PrivateFailureRecords();
      final projects = StudioStore(records);
      await projects.save([original]);
      // The preservation case starts with an in-memory starter; metadata writes
      // start with an already saved application whose bytes must remain intact.
      if (key == projectKey) {
        final applications = ApplicationStore(records);
        await applications.save(original.id, applications.load(original));
      }
      final before = Map<String, String>.from(records.values);
      final controller = ProjectDetailsController(
        original,
        ProjectDetailsStore(projects),
      );
      addTearDown(controller.dispose);
      records.throwKey = key;
      expect(await controller.save('Renamed', 'Updated intent'), false);
      expect(controller.error, isNotNull);
      for (final marker in ['PRIVATE_PROMPT', 'token=secret', '/private/']) {
        expect(controller.error, isNot(contains(marker)));
      }
      expect(controller.error, contains('Reopen'));
      expect(controller.project, same(original));
      expect(controller.busy, false);
      expect(records.values, before);
      records.throwKey = null;
      expect(await controller.save('Renamed', 'Updated intent'), true);
      expect(controller.error, isNull);
      expect(projects.load().single.name, 'Renamed');
      expect(projects.load(), hasLength(1));
      if (key == projectKey) expect(records.values[appKey], before[appKey]);
    });
  }

  test('late failed details write cannot publish after disposal', () async {
    final records = PrivateFailureRecords();
    final projects = StudioStore(records);
    await projects.save([original]);
    final before = Map<String, String>.from(records.values);
    records.throwKey = appKey;
    records.failureGate = Completer<void>();
    final controller = ProjectDetailsController(
      original,
      ProjectDetailsStore(projects),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);
    final saving = controller.save('Renamed', 'Updated intent');
    controller.dispose();
    final count = notifications;
    records.failureGate!.complete();
    expect(await saving, false);
    expect(controller.error, isNull);
    expect(notifications, count);
    expect(controller.project, same(original));
    expect(records.values, before);
  });
}

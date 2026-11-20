// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/imported_git_metadata_controller.dart';
import 'package:asg/models/git_head_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/git_metadata_host.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:flutter_test/flutter_test.dart';

GitHeadObservation sampleObservation() => GitHeadObservation.parse(
  jsonEncode({
    'version': 1,
    'layout': 'direct-dotgit-files',
    'scope': 'literal-file-declarations',
    'status': 'observed',
    'head_form': 'symbolic',
    'declared_ref': 'refs/heads/main',
    'declared_oid': 'a' * 40,
    'oid_source': 'loose_ref',
    'reason': null,
    'git_state_verified': false,
    'working_tree': 'unknown',
    'ahead_behind': 'unknown',
    'conflict': 'unknown',
  }),
);

class NoWriteRecords implements RecordStorage {
  @override
  String? getString(String key) => null;
  @override
  Future<bool> setString(String key, String value) =>
      throw StateError('No writes');
}

class SetupFixture extends RuntimeSetupStore {
  SetupFixture() : super(NoWriteRecords());
  String python = '/trusted/python';
  bool fail = false;
  int loads = 0;
  @override
  RuntimeSetup load() {
    loads++;
    if (fail) throw StateError('private-sentinel');
    return RuntimeSetup(python: python);
  }
}

class MetadataHostFixture implements GitMetadataHost {
  @override
  bool supported = true;
  final requests = <GitMetadataReadRequest>[];
  int cancellations = 0, disposals = 0;
  Future<GitHeadObservation> Function()? read;
  Future<void> Function()? stop;
  @override
  Future<GitHeadObservation> inspect(GitMetadataReadRequest request) {
    requests.add(request);
    return read?.call() ?? Future.value(sampleObservation());
  }

  @override
  Future<void> cancel() {
    cancellations++;
    return stop?.call() ?? Future.value();
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

ImportedGitMetadataController controllerFixture(
  MetadataHostFixture host,
  SetupFixture setup,
) => ImportedGitMetadataController(
  root: '/selected/folder',
  host: host,
  setupStore: setup,
  now: () => DateTime.utc(2026, 11, 20),
);

void main() {
  test(
    'synchronous Stop or disposal on busy notification prevents dispatch',
    () async {
      for (final dispose in [false, true]) {
        final host = MetadataHostFixture();
        final controller = controllerFixture(host, SetupFixture());
        final request = controller.prepare()!;
        controller.addListener(() {
          if (!controller.busy) return;
          if (dispose) {
            controller.dispose();
          } else {
            unawaited(controller.cancel());
          }
        });
        await controller.inspect(request, confirmed: true);
        expect(host.requests, isEmpty);
        expect(controller.observation, isNull);
        controller.dispose();
      }
    },
  );
  test('opening and cancelled confirmation never inspect or write', () async {
    final h = MetadataHostFixture(), s = SetupFixture();
    final controller = controllerFixture(h, s);
    expect(h.requests, isEmpty);
    expect(s.loads, 0);
    final request = controller.prepare()!;
    expect(h.requests, isEmpty);
    expect(controller.prepare(), isNull);
    await controller.inspect(request, confirmed: false);
    expect(h.requests, isEmpty);
    expect(controller.confirming, isFalse);
    controller.dispose();
  });
  test(
    'one-action snapshot cannot be forged or retargeted by settings',
    () async {
      final h = MetadataHostFixture(), s = SetupFixture();
      final c = controllerFixture(h, s),
          pending = Completer<GitHeadObservation>();
      h.read = () => pending.future;
      final request = c.prepare()!;
      s.python = '/different/python';
      await c.inspect(
        const GitMetadataReadRequest(
          root: '/selected/folder',
          python: '/trusted/python',
        ),
        confirmed: true,
      );
      expect(h.requests, isEmpty);
      final work = c.inspect(request, confirmed: true);
      expect(c.busy, isTrue);
      expect(c.prepare(), isNull);
      expect(h.requests.single.python, '/trusted/python');
      expect(s.loads, 1);
      pending.complete(sampleObservation());
      await work;
      expect(c.observation!.gitStateVerified, isFalse);
      expect(c.stale, isFalse);
      c.dispose();
    },
  );
  test('unsupported or invalid environment cannot start helper', () {
    final h = MetadataHostFixture(), s = SetupFixture();
    final c = controllerFixture(h, s);
    h.supported = false;
    expect(c.prepare(), isNull);
    expect(s.loads, 0);
    h.supported = true;
    for (final python in ['python3', '', '/bad\npython']) {
      s.python = python;
      expect(c.prepare(), isNull);
    }
    s.fail = true;
    expect(c.prepare(), isNull);
    expect(c.error, isNot(contains('private-sentinel')));
    expect(h.requests, isEmpty);
    c.dispose();
  });
  test(
    'transport failure keeps prior reading stale and waits cleanup',
    () async {
      final h = MetadataHostFixture(),
          c = controllerFixture(MetadataHostFixture(), SetupFixture());
      c.dispose();
      final controller = controllerFixture(h, SetupFixture());
      await controller.inspect(controller.prepare()!, confirmed: true);
      final prior = controller.observation, time = controller.readAt;
      final cleanup = Completer<void>();
      h.read = () => Future.error(StateError('private-sentinel'));
      h.stop = () => cleanup.future;
      final work = controller.inspect(controller.prepare()!, confirmed: true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.busy, isTrue);
      expect(controller.stale, isTrue);
      expect(controller.prepare(), isNull);
      expect(controller.observation, same(prior));
      expect(controller.error, isNot(contains('private-sentinel')));
      cleanup.complete();
      await work;
      expect(controller.busy, isFalse);
      expect(controller.readAt, time);
      controller.dispose();
    },
  );
  test(
    'cancelled late success cannot publish or unblock before cleanup',
    () async {
      final h = MetadataHostFixture(),
          c = controllerFixture(MetadataHostFixture(), SetupFixture());
      c.dispose();
      final controller = controllerFixture(h, SetupFixture());
      final read = Completer<GitHeadObservation>(), cleanup = Completer<void>();
      h.read = () => read.future;
      h.stop = () => cleanup.future;
      final work = controller.inspect(controller.prepare()!, confirmed: true);
      final stop = controller.cancel();
      read.complete(sampleObservation());
      await Future<void>.delayed(Duration.zero);
      expect(controller.busy, isTrue);
      expect(controller.observation, isNull);
      expect(controller.prepare(), isNull);
      cleanup.complete();
      await stop;
      await work;
      expect(controller.busy, isFalse);
      expect(h.cancellations, 1);
      controller.dispose();
    },
  );
  test(
    'failed cleanup blocks further attempts with private guidance',
    () async {
      final h = MetadataHostFixture(),
          c = controllerFixture(MetadataHostFixture(), SetupFixture());
      c.dispose();
      final controller = controllerFixture(h, SetupFixture()),
          read = Completer<GitHeadObservation>();
      h.read = () => read.future;
      h.stop = () => Future.error(StateError('private-sentinel'));
      final work = controller.inspect(controller.prepare()!, confirmed: true);
      await controller.cancel();
      read.completeError(StateError('cancelled'));
      await work;
      expect(controller.cleanupUncertain, isTrue);
      expect(controller.prepare(), isNull);
      expect(controller.error, isNot(contains('private-sentinel')));
      controller.dispose();
    },
  );
  test(
    'dispose drains owned cleanup and discards late notification/result',
    () async {
      final h = MetadataHostFixture(),
          c = controllerFixture(MetadataHostFixture(), SetupFixture());
      c.dispose();
      final controller = controllerFixture(h, SetupFixture()),
          read = Completer<GitHeadObservation>();
      h.read = () => read.future;
      var notifications = 0;
      controller.addListener(() => notifications++);
      final work = controller.inspect(controller.prepare()!, confirmed: true);
      controller.dispose();
      final before = notifications;
      read.complete(sampleObservation());
      await work;
      expect(notifications, before);
      expect(controller.observation, isNull);
      expect(h.disposals, 1);
      expect(controller.prepare(), isNull);
    },
  );
}

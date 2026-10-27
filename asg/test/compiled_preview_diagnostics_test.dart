import 'dart:async';

import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'source_generation_controller_test.dart'
    show FixtureHost, project, definition, generated;

const secret = 'PRIVATE_PROMPT token-secret /private/user/source';

class PreviewHost extends FixtureHost {
  String? failure;
  Completer<void>? gate;
  int opens = 0, stops = 0;
  @override
  Future<Uri> startPreview(GeneratedProject project) async {
    if (failure == 'start') throw StateError(secret);
    return super.startPreview(project);
  }

  @override
  Future<void> openPreview(Uri uri) async {
    opens++;
    await gate?.future;
    if (failure == 'open') throw StateError(secret);
  }

  @override
  Future<void> stopPreview() async {
    stops++;
    await gate?.future;
    if (failure == 'stop') throw StateError(secret);
    await super.stopPreview();
  }
}

void main() {
  late PreviewHost host;
  late SourceGenerationStore store;
  late SourceGenerationController c;
  late String saved;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = SourceGenerationStore(
      PreferenceRecords(await SharedPreferences.getInstance()),
    );
    await store.save(project.id, generated);
    saved = store.records.getString('studio.generation.v1.p')!;
    host = PreviewHost();
    c = SourceGenerationController(
      project: project,
      definition: definition,
      store: store,
      host: host,
    );
  });
  tearDown(() {
    expect(store.records.getString('studio.generation.v1.p'), saved);
    if (!c.isDisposed) c.dispose();
  });
  for (final operation in ['start', 'open', 'stop']) {
    test(
      'compiled preview $operation failure is private and retry clears it',
      () async {
        if (operation != 'start') await c.startPreview();
        final uri = c.preview;
        host.failure = operation;
        Future<void> act() => operation == 'start'
            ? c.startPreview()
            : operation == 'open'
            ? c.openPreview()
            : c.stopPreview();
        await act();
        expect(c.error, isNot(contains(secret)));
        expect(c.error, contains('Retry'));
        if (operation == 'stop') expect(c.error, contains('not confirmed'));
        expect(c.preview, uri);
        expect(c.busy, isFalse);
        host.failure = null;
        await act();
        expect(c.error, isNull);
        expect(c.preview, operation == 'stop' ? isNull : isNotNull);
      },
    );
  }
  test(
    'compiled preview ignores a late start failure after disposal',
    () async {
      host.previewGate = Completer<Uri>();
      final starting = c.startPreview();
      expect(c.busy, isTrue);
      await c.openPreview();
      await c.stopPreview();
      expect(host.stops, 0);
      c.dispose();
      host.previewGate!.completeError(StateError(secret));
      await starting;
      expect(c.error, isNull);
      expect(c.busy, isFalse);
    },
  );
  for (final operation in ['open', 'stop']) {
    test(
      'compiled preview $operation serializes actions and ignores late errors',
      () async {
        await c.startPreview();
        host.gate = Completer<void>();
        host.failure = operation;
        final running = operation == 'open' ? c.openPreview() : c.stopPreview();
        expect(c.busy, isTrue);
        await c.openPreview();
        await c.stopPreview();
        expect(host.opens, operation == 'open' ? 1 : 0);
        expect(host.stops, operation == 'stop' ? 1 : 0);
        c.dispose();
        host.gate!.complete();
        await running;
        expect(c.error, isNull);
        expect(c.busy, isFalse);
      },
    );
  }
}

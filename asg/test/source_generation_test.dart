@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/build_task.dart';
import 'package:asg/models/plan_approval.dart';

import 'package:asg/models/app_definition.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/generation_input.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

const project = StudioProject(
  id: 'generated-test',
  name: 'Generated task app',
  description: 'A task planner',
  type: 'Flutter',
  platforms: ['Web'],
  location: '',
);
const definition = AppDefinition(
  title: 'Generated task app',
  theme: 'green',
  elements: [
    AppElement(
      id: 'counter',
      kind: ElementKind.counter,
      label: 'Visits',
      value: '3',
    ),
    AppElement(
      id: 'tasks',
      kind: ElementKind.taskList,
      label: 'Tasks',
      items: ['A task'],
      completed: [0],
    ),
    AppElement(
      id: 'notes',
      kind: ElementKind.notes,
      label: 'Notes',
      value: 'Keep this',
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global =
      null; // Isolated native-host test file requires actual loopback.
  late Directory temp;
  late String sdk;
  late NativeGenerationHost host;
  Future<String> assets(String name) => File(name).readAsString();
  Future<GeneratedProject> generate({
    String name = 'generated_app',
    String? parent,
    void Function()? authorizeWrite,
  }) => host.generate(
    project: project,
    definition: definition,
    parent: parent ?? temp.path,
    name: name,
    sdk: sdk,
    python: 'python3',
    authorizeWrite: authorizeWrite,
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('asg-generator-test-');
    temp = Directory(await temp.resolveSymbolicLinks());
    sdk = '${temp.path}/sdk';
    await Directory('$sdk/bin').create(recursive: true);
    await File('$sdk/bin/flutter').writeAsString('fixture');
    host = NativeGenerationHost(
      loadAsset: assets,
      runOperation: (generated, operation) async {
        if (operation == 'build') {
          final directory = Directory('${generated.directory}/build/web');
          await directory.create(recursive: true);
          await File('${directory.path}/index.html')
              .writeAsString('<base href="/">Actual fixture');
          await File('${directory.path}/main.dart.js').writeAsString('fixture');
        }
        return GenerationStep(
          operation: operation,
          exitCode: 0,
          output: 'passed',
        );
      },
    );
  });
  tearDown(() async {
    await host.stopPreview();
    await temp.delete(recursive: true);
  });

  test('approval guard refuses creation after path preparation', () async {
    var checks = 0;
    await expectLater(
      generate(
        authorizeWrite: () {
          if (++checks == 2) throw StateError('Approval withdrawn');
        },
      ),
      throwsStateError,
    );
    expect(checks, 2);
    expect(await Directory('${temp.path}/generated_app').exists(), isFalse);
  });

  test('approval changes during asset loading stop all file writes', () async {
    var approved = true;
    host = NativeGenerationHost(
      loadAsset: (name) async {
        final asset = await assets(name);
        approved = false;
        return asset;
      },
    );
    await expectLater(
      generate(
        authorizeWrite: () {
          if (!approved) throw StateError('Approval withdrawn');
        },
      ),
      throwsStateError,
    );
    final destination = Directory('${temp.path}/generated_app');
    expect(await destination.exists(), isTrue);
    expect(await destination.list().toList(), isEmpty);
  });

  test('later authorization refusal preserves partial files', () async {
    final destination = Directory('${temp.path}/generated_app');
    Map<String, String>? retained;
    await expectLater(
      generate(
        authorizeWrite: () {
          if (!destination.existsSync()) return;
          final files = destination.listSync(recursive: true).whereType<File>();
          if (files.any((file) => file.lengthSync() > 0)) {
            retained = {
              for (final file in files) file.path: file.readAsStringSync(),
            };
            throw StateError('Approval withdrawn');
          }
        },
      ),
      throwsStateError,
    );
    expect(retained, isNotEmpty);
    expect({
      for (final file
          in destination.listSync(recursive: true).whereType<File>())
        file.path: file.readAsStringSync(),
    }, retained);
  });

  test(
    'writes portable MVC source and treats hostile labels as JSON data',
    () async {
      final generated = await generate();
      expect(
        GenerationInput(project, definition).compare(generated),
        GeneratedSnapshotStatus.current,
      );
      expect(
        generated.sources.keys,
        containsAll([
          'lib/models/app_definition.dart',
          'lib/controllers/generated_controller.dart',
          'lib/views/generated_app.dart',
          'asg_project.json',
        ]),
      );
      expect(
        jsonDecode(
          await File('${generated.directory}/assets/app.json').readAsString(),
        ),
        definition.toJson(),
      );
      final hostile = AppDefinition(
        title: '\${danger()} <script> 😀 & "quote"',
        theme: 'pink',
        elements: definition.elements,
      );
      final second = await host.generate(
        project: project,
        definition: hostile,
        parent: temp.path,
        name: 'hostile_data',
        sdk: sdk,
        python: 'python3',
      );
      expect(
        GenerationInput(project, hostile).compare(second),
        GeneratedSnapshotStatus.current,
      );
      expect(
        await File('${second.directory}/lib/main.dart').readAsString(),
        isNot(contains('danger')),
      );
      expect(
        await File('${second.directory}/web/index.html').readAsString(),
        isNot(contains('danger')),
      );
      expect(
        jsonDecode(
          await File('${second.directory}/assets/app.json').readAsString(),
        )['title'],
        hostile.title,
      );
    },
  );

  test(
    'rejects traversal, existing folders/files and symbolic-link parents',
    () async {
      for (final name in ['../escape', '/absolute', 'x/y', 'bad-name', '.']) {
        await expectLater(generate(name: name), throwsFormatException);
      }
      final existing = Directory('${temp.path}/generated_app');
      await existing.create();
      final marker = File('${existing.path}/keep');
      await marker.writeAsString('retain');
      await expectLater(generate(), throwsStateError);
      expect(await marker.readAsString(), 'retain');
      await File('${temp.path}/existing_file').writeAsString('retain');
      await expectLater(generate(name: 'existing_file'), throwsStateError);
      await Link('${temp.path}/linked_parent').create(temp.path);
      await expectLater(
        generate(parent: '${temp.path}/linked_parent'),
        throwsFormatException,
      );
      expect(
        await FileSystemEntity.type('${temp.path}/escape'),
        FileSystemEntityType.notFound,
      );
    },
  );

  test(
    'exclusive files preserve entries introduced during preparation',
    () async {
      host = NativeGenerationHost(
        loadAsset: (name) async {
          await File('${temp.path}/generated_app/pubspec.yaml')
              .writeAsString('retain concurrent entry');
          return assets(name);
        },
      );
      await expectLater(generate(), throwsA(isA<FileSystemException>()));
      expect(
        await File('${temp.path}/generated_app/pubspec.yaml').readAsString(),
        'retain concurrent entry',
      );
    },
  );

  test('permission-denied destination preserves the parent', () async {
    if (Platform.environment['USER'] == 'root') return;
    final locked = await Directory('${temp.path}/read_only').create();
    await Process.run('/bin/chmod', ['500', locked.path]);
    try {
      await expectLater(generate(parent: locked.path), throwsStateError);
      expect(
        await FileSystemEntity.type('${locked.path}/generated_app'),
        FileSystemEntityType.notFound,
      );
    } finally {
      await Process.run('/bin/chmod', ['700', locked.path]);
    }
  });

  test(
    'real runner preparation failure records task without an exit',
    () async {
      final generated = await generate();
      final events = <GeneratedProject>[];
      final native = NativeGenerationHost(loadAsset: assets);
      await expectLater(
        native.verify(generated, (event) async => events.add(event)),
        throwsStateError,
      );
      final failed = GeneratedProject.fromJson(events.last.toJson());
      expect(failed.failedOperation, 'resolve');
      expect(failed.phase, SourceGenerationPhase.failed);
      expect(failed.steps, isEmpty);
      expect(failed.error, contains('already initialized Flutter SDK'));
      await native.dispose();
    },
  );

  test(
    'runner exceptions identify failed task and retry clears identity',
    () async {
      final generated = await generate();
      final events = <GeneratedProject>[];
      final operations = <String>[];
      final failing = NativeGenerationHost(
        loadAsset: assets,
        runOperation: (_, operation) async {
          operations.add(operation);
          if (operation == 'analyze') {
            throw StateError('Interpreter unavailable');
          }
          return GenerationStep(
            operation: operation,
            exitCode: 0,
            output: 'actual',
          );
        },
      );
      await expectLater(
        failing.verify(generated, (event) async => events.add(event)),
        throwsStateError,
      );
      final failed = GeneratedProject.fromJson(events.last.toJson());
      expect(operations, ['resolve', 'analyze']);
      expect(failed.phase, SourceGenerationPhase.failed);
      expect(failed.failedOperation, 'analyze');
      expect(failed.steps.map((step) => step.operation), ['resolve']);
      expect(failed.error, contains('Interpreter unavailable'));
      final ready = await host.verify(failed, (event) async {
        expect(event.failedOperation, isEmpty);
      });
      expect(ready.phase, SourceGenerationPhase.ready);
      await failing.dispose();
    },
  );

  test(
    'partial verification records failure and can retry unchanged source',
    () async {
      final generated = (await generate()).copy(
        approval: PlanApproval(
          messageIndex: 0,
          content: 'Fixed starter',
          context: 'revision 1',
          approved: true,
          recordedAt: DateTime.utc(2026),
        ),
        tasks: BuildTask.starter,
      );
      final events = <GeneratedProject>[];
      final failing = NativeGenerationHost(
        loadAsset: assets,
        runOperation: (_, operation) async => GenerationStep(
          operation: operation,
          exitCode: operation == 'test' ? 1 : 0,
          output: 'fixture',
        ),
      );
      final failed = await failing.verify(
        generated,
        (event) async => events.add(event),
      );
      expect(failed.phase, SourceGenerationPhase.failed);
      expect(
        failed.taskStatus(failed.tasks![2], active: false),
        BuildTaskStatus.failed,
      );
      expect(
        failed.taskStatus(failed.tasks![3], active: false),
        BuildTaskStatus.blocked,
      );
      expect(
        events.every(
          (e) => e.tasks != null && e.approval!.matches(generated.approval!),
        ),
        isTrue,
      );
      expect(failed.steps.map((s) => s.operation), [
        'resolve',
        'analyze',
        'test',
      ]);
      expect(events.first.phase, SourceGenerationPhase.verifying);
      final ready = await host.verify(failed.copy(sdk: '$sdk/'), (_) async {});
      expect(ready.sdk, sdk);
      expect(ready.phase, SourceGenerationPhase.ready);
      expect(ready.outputs, contains('main.dart.js'));
      await File('${generated.directory}/lib/main.dart')
          .writeAsString('modified');
      await expectLater(host.verify(ready, (_) async {}), throwsStateError);
      await expectLater(host.startPreview(ready), throwsStateError);
    },
  );

  test(
    'progress refusal before an operation prevents command execution',
    () async {
      final generated = await generate();
      final operations = <String>[];
      final guarded = NativeGenerationHost(
        loadAsset: assets,
        runOperation: (_, operation) async {
          operations.add(operation);
          return GenerationStep(
            operation: operation,
            exitCode: 0,
            output: 'fixture',
          );
        },
      );
      var boundaries = 0;
      await expectLater(
        guarded.verify(generated, (event) async {
          boundaries++;
          if (boundaries == 2) throw StateError('Approval withdrawn');
        }),
        throwsStateError,
      );
      expect(boundaries, 2);
      expect(operations, isEmpty);
      await guarded.dispose();
    },
  );

  test(
    'approval is checked after helper preparation before process launch',
    () async {
      final marker = File('${temp.path}/command-started');
      await File('$sdk/bin/flutter')
          .writeAsString('#!/bin/sh\ntouch "${marker.path}"\nexit 0\n');
      await Process.run('/bin/chmod', ['700', '$sdk/bin/flutter']);
      for (final relative in [
        'bin/cache/flutter_tools.snapshot',
        'bin/cache/dart-sdk/bin/dart',
        'packages/flutter_tools/.dart_tool/package_config.json',
      ]) {
        final file = File('$sdk/$relative');
        await file.parent.create(recursive: true);
        await file.writeAsString('fixture');
      }
      final generated = await generate();
      final guarded = NativeGenerationHost(loadAsset: assets);
      var approved = true;
      var boundaries = 0;
      await expectLater(
        guarded.verify(generated, (_) async {
          boundaries++;
          if (!approved) {
            throw StateError('Approval withdrawn during preparation');
          }
          if (boundaries == 2) scheduleMicrotask(() => approved = false);
        }),
        throwsStateError,
      );
      expect(
        await marker.exists(),
        isFalse,
        reason: 'Withdrawal before process launch must deny the command',
      );
      await guarded.dispose();
    },
  );

  test(
    'actual preview serves only fingerprinted output behind an ephemeral path',
    () async {
      final ready = await host.verify(await generate(), (_) async {});
      final uri = await host.startPreview(ready);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(uri)).close();
        expect(response.statusCode, 200);
        expect(
          await utf8.decodeStream(response),
          contains('<base href="${uri.path}">'),
        );
        final forbidden = await (await client.getUrl(uri.resolve('/'))).close();
        expect(forbidden.statusCode, 403);
        await forbidden.drain<void>();
        final source = await (await client.getUrl(uri.resolve('lib/main.dart')))
            .close();
        expect(source.statusCode, 404);
        await source.drain<void>();
        final navigation = await client.getUrl(uri);
        navigation.headers.set('Sec-Fetch-Site', 'cross-site');
        navigation.headers.set('Sec-Fetch-Mode', 'navigate');
        navigation.headers.set('Sec-Fetch-Dest', 'document');
        final navigationResponse = await navigation.close();
        expect(navigationResponse.statusCode, 200);
        await navigationResponse.drain<void>();
        final crossSiteRequest = await client.getUrl(uri);
        crossSiteRequest.headers.set('Origin', 'https://example.com');
        final crossSite = await crossSiteRequest.close();
        expect(crossSite.statusCode, 403);
        await crossSite.drain<void>();
        await File('${ready.directory}/build/web/main.dart.js')
            .writeAsString('modified');
        final changed = await (await client.getUrl(uri.resolve('main.dart.js')))
            .close();
        expect(changed.statusCode, 409);
        await changed.drain<void>();
        await expectLater(host.startPreview(ready), throwsStateError);
        await host.stopPreview();
        await expectLater(
          client.getUrl(uri).then((request) => request.close()),
          throwsA(anything),
        );
      } finally {
        client.close(force: true);
      }
    },
  );

  for (final (exitCode, timedOut) in [(0, false), (1, false), (0, true)]) {
    test(
      'retains resolve evidence before unsafe metadata (exit=$exitCode timeout=$timedOut)',
      () async {
        final prepared = await generate();
        var calls = 0;
        GeneratedProject? recorded;
        host = NativeGenerationHost(
          loadAsset: assets,
          runOperation: (project, operation) async {
            calls++;
            final target = File('${temp.path}/metadata-target');
            await target.writeAsString('untrusted');
            await Link('${project.directory}/pubspec.lock').create(target.path);
            return GenerationStep(
              operation: operation,
              exitCode: exitCode,
              output: 'actual resolve evidence',
              timedOut: timedOut,
            );
          },
        );
        Future<void> progress(GeneratedProject value) async => recorded = value;
        if (exitCode == 0 && !timedOut) {
          await expectLater(host.verify(prepared, progress), throwsStateError);
        } else {
          expect(
            (await host.verify(prepared, progress)).phase,
            SourceGenerationPhase.failed,
          );
        }
        expect(calls, 1);
        expect(recorded!.steps.single.operation, 'resolve');
        expect(recorded!.steps.single.exitCode, exitCode);
        expect(recorded!.steps.single.timedOut, timedOut);
        expect(recorded!.steps.single.output, 'actual resolve evidence');
        await expectLater(host.verify(recorded!, progress), throwsStateError);
        expect(calls, 1);
      },
    );
  }

  test('changed dependency metadata blocks later commands and retry', () async {
    final prepared = await generate();
    var calls = 0;
    GeneratedProject? recorded;
    host = NativeGenerationHost(
      loadAsset: assets,
      runOperation: (project, operation) async {
        calls++;
        final metadata = File(
          '${project.directory}/.dart_tool/package_config.json',
        );
        await metadata.parent.create(recursive: true);
        await metadata.writeAsString('approved fixture');
        return GenerationStep(
          operation: operation,
          exitCode: 0,
          output: 'fixture',
        );
      },
    );
    await expectLater(
      host.verify(prepared, (value) async {
        recorded = value;
        if (value.steps.isNotEmpty) {
          await File('${prepared.directory}/.dart_tool/package_config.json')
              .writeAsString('modified execution input');
        }
      }),
      throwsStateError,
    );
    expect(calls, 1);
    await expectLater(host.verify(recorded!, (_) async {}), throwsStateError);
    expect(calls, 1);
  });

  test(
    'real independent generated Flutter project analyzes, tests, builds and serves',
    () async {
      var realSdk =
          Platform.environment['ASG_FLUTTER_SDK'] ??
          Platform.environment['FLUTTER_ROOT'];
      var ancestor = File(Platform.resolvedExecutable).parent;
      while (realSdk == null && ancestor.parent.path != ancestor.path) {
        if (await File('${ancestor.path}/bin/flutter').exists()) {
          realSdk = ancestor.path;
        }
        ancestor = ancestor.parent;
      }
      if (realSdk == null) {
        throw StateError('Set ASG_FLUTTER_SDK for opt-in generation test.');
      }
      host = NativeGenerationHost(loadAsset: assets);
      final generated = await host.generate(
        project: project,
        definition: definition,
        parent: temp.path,
        name: 'real_generated_app',
        sdk: realSdk,
        python: 'python3',
      );
      final ready = await host.verify(generated, (event) async {
        if (event.steps.isNotEmpty) {
          debugPrint(
            '${event.steps.last.operation}: ${event.steps.last.exitCode}\n${event.steps.last.output}',
          );
        }
      });
      expect(ready.phase, SourceGenerationPhase.ready, reason: ready.error);
      final uri = await host.startPreview(ready);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(
          uri.resolve('main.dart.js'),
        )).close();
        expect(response.statusCode, 200);
        expect(
          (await response.fold<int>(0, (total, bytes) => total + bytes.length)),
          greaterThan(1000),
        );
      } finally {
        if (const bool.fromEnvironment('ASG_BROWSER_REVIEW')) {
          debugPrint('ASG_REVIEW_PREVIEW=$uri');
          await Future<void>.delayed(const Duration(seconds: 180));
        }
        client.close(force: true);
      }
    },
    skip: !const bool.fromEnvironment('ASG_REAL_GENERATION'),
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

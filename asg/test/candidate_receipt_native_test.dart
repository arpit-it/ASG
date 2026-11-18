// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/plan_approval.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/candidate_receipt_native.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    test(
      'native receipt fixtures require POSIX file descriptors',
      () {},
      skip: 'Unavailable platform acceptance remains deferred under #400.',
    );
    return;
  }
  final producer = Platform.environment['ASG_RECEIPT_PRODUCER'];
  if (producer != null) {
    test('disposable receipt producer', () async {
      final input = jsonDecode(producer) as Map<String, dynamic>;
      final run = CandidateVerificationRun.fromJson(
        input['run'] as Map<String, dynamic>,
      );
      final files = CandidateReceiptFiles(
        root: () async => Directory(input['root'] as String),
      );
      final directory = await files.prepare(run, () {});
      final tools = Directory('tools').absolute.path;
      final script =
          'import sys; sys.path.insert(0,${jsonEncode(tools)}); '
          'import generation_command as g; '
          'r=g.CompletionReceipt(${jsonEncode(directory)},'
          '${jsonEncode(run.snapshot.directory)},${jsonEncode(run.snapshot.sdk)},"resolve"); '
          'r.publish(g.run(sys.executable,["-c", "print(123)"],'
          '${jsonEncode(run.snapshot.directory)},3)); r.close()';
      final result = await Process.run('python3', ['-I', '-B', '-c', script]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });
    return;
  }
  late Directory temporary, candidate, sdk, root;
  late CandidateVerificationRun run;
  late CandidateReceiptFiles files;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('asg-receipt-files-');
    temporary = Directory(await temporary.resolveSymbolicLinks());
    candidate = await Directory('${temporary.path}/candidate').create();
    sdk = await Directory('${temporary.path}/sdk').create();
    root = Directory('${temporary.path}/receipts');
    files = CandidateReceiptFiles(root: () async => root);
    run = CandidateVerificationRun(
      number: 1,
      startedAt: DateTime.utc(2026),
      finished: false,
      dispatchId: 'candidate-p-1:3',
      snapshot: GeneratedProject(
        directory: candidate.path,
        sdk: sdk.path,
        python: 'python3',
        sources: {'lib/main.dart': 'a' * 64},
        confined: true,
        checkpointVersion: 1,
        phase: SourceGenerationPhase.verifying,
        pendingOperation: 'resolve',
        approval: PlanApproval(
          messageIndex: 0,
          content: 'recorded approval',
          context: 'inputs',
          approved: true,
          recordedAt: DateTime.utc(2026),
        ),
      ),
    );
  });
  tearDown(() async => temporary.delete(recursive: true));

  Future<void> publish(String directory) async {
    final tools = Directory('tools').absolute.path;
    final command = jsonEncode("print('retained actual output')");
    final script =
        'import sys; sys.path.insert(0,${jsonEncode(tools)}); '
        'import generation_command as g; '
        'r=g.CompletionReceipt(${jsonEncode(directory)},${jsonEncode(candidate.path)},${jsonEncode(sdk.path)},"resolve"); '
        'result=g.run(sys.executable,["-c",$command],${jsonEncode(candidate.path)},3); '
        'r.publish(result); r.close()';
    final result = await Process.run('python3', ['-I', '-B', '-c', script]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  for (final lostOutput in [false, true]) {
    test('native prepared receipt with lost delivery=$lostOutput', () async {
      for (final relative in [
        'bin/flutter',
        'bin/cache/flutter_tools.snapshot',
        'bin/cache/dart-sdk/bin/dart',
        'packages/flutter_tools/.dart_tool/package_config.json',
      ]) {
        final file = File('${sdk.path}/$relative');
        await file.parent.create(recursive: true);
        await file.writeAsString('controlled adapter fixture');
      }
      final snapshot = GeneratedProject(
        directory: candidate.path,
        sdk: sdk.path,
        python: 'python3',
        sources: await NativeGenerationHost.fingerprints(
          candidate.path,
          source: true,
        ),
        confined: true,
        approval: run.snapshot.approval,
        checkpointVersion: 1,
      );
      final dispatched = CandidateVerificationRun(
        number: run.number,
        startedAt: run.startedAt,
        snapshot: snapshot,
        finished: false,
        dispatchId: run.dispatchId,
      );
      final tools = Directory('tools').absolute.path;
      final script =
          'import sys,json; sys.path.insert(0,${jsonEncode(tools)}); '
          'import generation_command as g; '
          'args=sys.argv; directory=args[args.index("--directory")+1]; sdk=args[args.index("--sdk")+1]; '
          'operation=args[args.index("--operation")+1]; receipt=args[args.index("--completion-receipts")+1]; '
          'writer=g.CompletionReceipt(receipt,directory,sdk,operation); '
          'result=g.run(sys.executable,["-c","print(123); raise SystemExit(7)"],directory,3); '
          'writer.publish(result); writer.close(); ${lostOutput ? 'raise SystemExit(23)' : 'print(json.dumps(result))'}';
      final host = NativeGenerationHost(
        receiptFiles: files,
        loadAsset: (_) async => script,
      );
      addTearDown(host.dispose);
      await host.prepareCandidateReceipts(dispatched, () {});
      var observedCompletion = false;
      GeneratedProject? pending;
      final verification = host.verify(snapshot, (value) async {
        pending = value;
        if (value.steps.isNotEmpty) {
          observedCompletion = true;
          expect(
            (await host.readCandidateReceipts(dispatched))
                .single
                .result
                .exitCode,
            7,
          );
        }
      });
      if (lostOutput) {
        await expectLater(verification, throwsFormatException);
        expect(observedCompletion, isFalse);
        expect(pending!.pendingOperation, 'resolve');
        expect(pending!.steps, isEmpty);
        expect(
          (await host.readCandidateReceipts(dispatched)).single.result.exitCode,
          7,
        );
      } else {
        final failed = await verification;
        expect(observedCompletion, isTrue);
        expect(failed.steps.single.exitCode, 7);
        expect(failed.steps.single.output, '123\n');
        expect(failed.phase, SourceGenerationPhase.failed);
      }
    });
  }

  test('receipt survives disposable Flutter producer process exit', () async {
    final sdkRoot = Platform.environment['FLUTTER_ROOT'];
    expect(
      sdkRoot,
      isNotNull,
      reason: 'The existing Flutter test SDK is required.',
    );
    final before = jsonEncode(run.toJson());
    final journal = File('${temporary.path}/journal.json');
    final working = File('${temporary.path}/last-working.txt');
    await journal.writeAsString(before);
    await working.writeAsString('preserved output');
    final script =
        'import sys,json; sys.path.insert(0,${jsonEncode(Directory('tools').absolute.path)}); '
        'import generation_command as g; '
        'r=g.run(${jsonEncode('$sdkRoot/bin/flutter')},'
        '["test","--no-pub","--timeout","20s",'
        '"test/candidate_receipt_native_test.dart",'
        '"--plain-name","disposable receipt producer"],'
        '${jsonEncode(Directory.current.path)},60); '
        'print(json.dumps(r)); sys.exit(0 if r["exitCode"]==0 else 1)';
    final child = await Process.run(
      'python3',
      ['-I', '-B', '-c', script],
      environment: {
        'ASG_RECEIPT_PRODUCER': jsonEncode({
          'run': run.toJson(),
          'root': root.path,
        }),
      },
    );
    expect(child.exitCode, 0, reason: '${child.stdout} ${child.stderr}');
    // Producer has exited; a new service reads the unchanged serialized journal.
    final restored = CandidateVerificationRun.fromJson(
      jsonDecode(await journal.readAsString()) as Map<String, dynamic>,
    );
    final retained = await CandidateReceiptFiles(root: () async => root)
        .read(restored);
    expect(retained.single.result.exitCode, 0);
    expect(retained.single.result.output, '123\n');
    final results = await root
        .list(recursive: true)
        .where((entry) => entry.path.endsWith('/resolve.result.json'))
        .toList();
    final record = jsonDecode(
      await File(results.single.path).readAsString(),
    ) as Map<String, dynamic>;
    expect(record['cleanup'], 'unknown');
    expect(restored.finished, isFalse);
    expect(restored.snapshot.pendingOperation, 'resolve');
    expect(await journal.readAsString(), before);
    expect(await working.readAsString(), 'preserved output');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('actual Python helper receipt survives a new reader without journal changes', () async {
    final before = jsonEncode(run.toJson());
    final directory = await files.prepare(run, () {});
    await publish(directory);
    final reopened = CandidateReceiptFiles(root: () async => root);
    final restoredRun = CandidateVerificationRun.fromJson(
      jsonDecode(jsonEncode(run.toJson())) as Map<String, dynamic>,
    );
    final receipts = await reopened.read(restoredRun);
    expect(receipts.single.context.dispatchId, run.dispatchId);
    expect(receipts.single.operation.name, 'resolve');
    expect(receipts.single.result.exitCode, 0);
    expect(receipts.single.result.output, 'retained actual output\n');
    expect(jsonEncode(run.toJson()), before);
    expect(run.finished, isFalse);
    expect(run.snapshot.pendingOperation, 'resolve');
    await expectLater(files.prepare(run, () {}), throwsStateError);
  });

  test('missing completion stays absent; corrupt or linked results stay unreadable', () async {
    final directory = await files.prepare(run, () {});
    expect(await files.read(run), isEmpty);
    await publish(directory);
    final result = File('$directory/resolve.result.json');
    final raw = await result.readAsString();
    await result.writeAsString('{private incomplete');
    await expectLater(
      files.read(run),
      throwsA(
        isA<FormatException>()
            .having((error) => error.source, 'source', isNull)
            .having(
              (error) => error.toString(),
              'redacted message',
              isNot(contains('private incomplete')),
            ),
      ),
    );
    expect(await result.readAsString(), '{private incomplete');
    await result.delete();
    final outside = await File('${temporary.path}/outside').writeAsString(raw);
    await Link(result.path).create(outside.path);
    await expectLater(files.read(run), throwsFormatException);
    expect(await outside.readAsString(), raw);
  });

  test('withdrawal after directory allocation publishes neither context nor result', () async {
    var checks = 0;
    await expectLater(
      files.prepare(run, () {
        checks++;
        if (checks == 3) throw StateError('withdrawn');
      }),
      throwsStateError,
    );
    final allocated = (await root.list().toList()).single as Directory;
    expect(await allocated.list().isEmpty, isTrue);
    await expectLater(files.read(run), throwsFormatException);
    expect(run.finished, isFalse);
    expect(run.snapshot.steps, isEmpty);
  });

  test(
    'native prepared identity cannot be applied to another verification',
    () async {
      var helperLoads = 0;
      final host = NativeGenerationHost(
        receiptFiles: files,
        loadAsset: (_) async {
          helperLoads++;
          throw StateError('Unexpected helper dispatch');
        },
      );
      addTearDown(host.dispose);
      await host.prepareCandidateReceipts(run, () {});
      await expectLater(
        host.verify(run.snapshot.copy(python: 'other-python'), (_) async {}),
        throwsStateError,
      );
      expect(helperLoads, 0);
      expect(await files.read(run), isEmpty);
      final directory = (await root.list().toList()).single as Directory;
      expect(
        await File('${directory.path}/resolve.intent.json').exists(),
        isFalse,
      );
    },
  );

  test('changed execution inputs cannot reuse a retained result', () async {
    final directory = await files.prepare(run, () {});
    await publish(directory);
    final changed = CandidateVerificationRun(
      number: run.number,
      startedAt: run.startedAt,
      snapshot: run.snapshot.copy(python: 'different-python'),
      finished: false,
      dispatchId: run.dispatchId,
    );
    await expectLater(files.read(changed), throwsStateError);
    expect((await files.read(run)).single.result.exitCode, 0);
  });

  test(
    'receipt directory with weakened permissions is not trusted on reopen',
    () async {
      final directory = await files.prepare(run, () {});
      await publish(directory);
      final changed = await Process.run('/bin/chmod', ['755', directory]);
      expect(changed.exitCode, 0);
      await expectLater(files.read(run), throwsStateError);
      expect(await File('$directory/resolve.result.json').exists(), isTrue);
    },
  );

  test(
    'mismatched identity and absent intent cannot supply a result',
    () async {
      final directory = await files.prepare(run, () {});
      await publish(directory);
      final result = File('$directory/resolve.result.json');
      final raw =
          jsonDecode(await result.readAsString()) as Map<String, dynamic>;
      (raw['context'] as Map<String, dynamic>)['dispatchId'] = 'other:3';
      await result.writeAsString(jsonEncode(raw));
      await expectLater(files.read(run), throwsFormatException);
      await File('$directory/resolve.intent.json').delete();
      await expectLater(files.read(run), throwsFormatException);
    },
  );

  test('withdrawn authority and candidate-overlapping roots create no receipt storage', () async {
    await expectLater(
      files.prepare(run, () => throw StateError('withdrawn')),
      throwsStateError,
    );
    expect(await root.exists(), isFalse);
    final inside = Directory('${candidate.path}/receipts');
    final unsafe = CandidateReceiptFiles(root: () async => inside);
    await expectLater(unsafe.prepare(run, () {}), throwsStateError);
    expect(await inside.exists(), isFalse);
    final linked = '${temporary.path}/linked';
    await Link(linked).create(candidate.path);
    await expectLater(
      CandidateReceiptFiles(root: () async => Directory(linked))
          .prepare(run, () {}),
      throwsStateError,
    );
    expect(await candidate.list().isEmpty, isTrue);
  });
  final realSdk = Platform.environment['ASG_REAL_RECEIPT_SDK'];
  test(
    'real confined Flutter resolve and analyze retain completion receipts',
    () async {
      final actualSdk = await Directory(realSdk ?? '').resolveSymbolicLinks();
      await File('${candidate.path}/pubspec.yaml').writeAsString(
        'name: asg_receipt_fixture\nenvironment:\n  sdk: ">=3.3.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\n',
      );
      final main = File('${candidate.path}/lib/main.dart');
      await main.parent.create();
      await main.writeAsString(
        "import 'package:flutter/widgets.dart';\nvoid main() => runApp(const SizedBox());\n",
      );
      final snapshot = GeneratedProject(
        directory: candidate.path,
        sdk: actualSdk,
        python: 'python3',
        sources: await NativeGenerationHost.fingerprints(
          candidate.path,
          source: true,
        ),
        confined: true,
        approval: run.snapshot.approval,
        checkpointVersion: 1,
      );
      final dispatched = CandidateVerificationRun(
        number: run.number,
        startedAt: run.startedAt,
        snapshot: snapshot,
        finished: false,
        dispatchId: run.dispatchId,
      );
      final directory = await files.prepare(dispatched, () {});
      final host = NativeGenerationHost(receiptFiles: files);
      addTearDown(host.dispose);
      for (final operation in ['resolve', 'analyze']) {
        final step = await host.runFlutterOperation(
          snapshot,
          operation,
          receiptDirectory: directory,
        );
        expect(step.exitCode, 0, reason: step.output);
      }
      final reopened = CandidateReceiptFiles(root: () async => root);
      final saved = await reopened.read(dispatched);
      expect(saved.map((item) => item.operation.name), ['resolve', 'analyze']);
      expect(saved.every((item) => item.result.exitCode == 0), isTrue);
      expect(dispatched.finished, isFalse);
    },
    skip: !Platform.isMacOS || realSdk == null,
  );
}

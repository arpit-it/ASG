// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:io';
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/model_download_host.dart';
import 'package:asg/views/runtime_setup_screen.dart';

import 'runtime_setup_test.dart' as setup;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/model_download.dart';
import 'package:asg/services/model_downloader_native.dart';
import 'package:asg/views/model_download_panel.dart';

class ControlledTransfer extends setup.FakeRuntimeHost
    implements ModelDownloadHost {
  @override
  ModelDownloadProgress downloadProgress = const ModelDownloadProgress();
  final updates = StreamController<ModelDownloadProgress>.broadcast();
  @override
  Stream<ModelDownloadProgress> get downloadEvents => updates.stream;
  Completer<String>? pending;
  int resumes = 0;
  @override
  Future<String> download(RuntimeSetup values) {
    pending = Completer<String>();
    downloadProgress = const ModelDownloadProgress(
      phase: DownloadPhase.downloading,
      bytes: 1024,
      total: 2048,
      bytesPerSecond: 512,
    );
    updates.add(downloadProgress);
    return pending!.future;
  }

  @override
  Future<String> resumeDownload(RuntimeSetup values) {
    resumes++;
    return download(values);
  }

  @override
  Future<void> pauseDownload() async {
    downloadProgress = downloadProgress.withPhase(DownloadPhase.paused);
    updates.add(downloadProgress);
    pending?.completeError(const DownloadInterrupted());
    pending = null;
  }

  @override
  Future<void> stopDownload() async {
    downloadProgress = downloadProgress.withPhase(DownloadPhase.stopped);
    updates.add(downloadProgress);
    pending?.completeError(const DownloadInterrupted());
    pending = null;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'controller interruption retains settings and never scans partial files',
    () async {
      final host = ControlledTransfer(),
          c = await setup.controller(ControlledTransfer());
      c.dispose();
      final controller = await setup.controller(host);
      controller.initialize();
      const values = RuntimeSetup(
        repository: 'owner/model',
        revision: 'pin',
        downloadParent: '/models',
      );
      final transfer = controller.download(values);
      await Future<void>.delayed(Duration.zero);
      expect(controller.busy, isTrue);
      await controller.pauseDownload();
      await transfer;
      expect(controller.error, isNull);
      expect(controller.selected, isNull);
      expect(controller.setup.revision, 'pin');
      expect(controller.status, contains('paused'));
      final resumed = controller.download(values, resume: true);
      await Future<void>.delayed(Duration.zero);
      expect(host.resumes, 1);
      await controller.stopDownload();
      await resumed;
      expect(controller.error, isNull);
      expect(controller.downloadProgress.phase, DownloadPhase.stopped);
      final disposed = controller.download(values);
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      await disposed;
      expect(host.downloadProgress.phase, DownloadPhase.stopped);
      await host.updates.close();
    },
  );
  testWidgets(
    'transfer panel is directly below download button and remains actionable while busy',
    (tester) async {
      final host = ControlledTransfer(),
          controller = await setup.controller(ControlledTransfer());
      controller.dispose();
      final c = await setup.controller(host);
      await tester.pumpWidget(
        MaterialApp(home: RuntimeSetupScreen(controller: c)),
      );
      await tester.pump();
      await tester.tap(find.text('Repository'));
      await tester.pump();
      final start = find.text('Download model & validate');
      final panel = find.byType(ModelDownloadPanel);
      await tester.ensureVisible(start);
      await tester.pump();
      expect(
        tester.getTopLeft(panel).dy,
        greaterThan(tester.getBottomLeft(start).dy),
      );
      expect(
        tester.getTopLeft(panel).dy - tester.getBottomLeft(start).dy,
        lessThan(60),
      );
      final running = c.download(const RuntimeSetup(repository: 'owner/model'));
      await tester.pump();
      await tester.pump();
      await tester.ensureVisible(find.text('Pause download'));
      await tester.pump();
      await tester.tap(find.text('Pause download'));
      await tester.pump();
      await running;
      expect(c.error, isNull);
      expect(find.text('Download paused'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await host.updates.close();
    },
  );
  test('numeric protocol rejects malformed private and impossible data', () {
    expect(
      ModelDownloadProgress.parse(
        '{"v":1,"event":"progress","bytes":1024,"total":2048,"speed":512}',
      )?.fraction,
      .5,
    );
    for (final line in [
      'PRIVATE',
      '{"v":1,"event":"progress","bytes":-1,"total":1,"speed":0}',
      '{"v":1,"event":"progress","bytes":2,"total":1,"speed":0}',
      '{"v":1,"event":"progress","bytes":2,"total":3,"speed":"PRIVATE"}',
      'x' * 2048,
    ]) {
      expect(ModelDownloadProgress.parse(line), isNull);
    }
  });
  test('actual process pause stop and resume retain partial bytes', () async {
    final root = await Directory.systemTemp.createTemp('asg transfer ');
    addTearDown(() => root.delete(recursive: true));
    final script = File('${root.path}/transfer.py');
    await script.writeAsString('''
import argparse,json,time,os
from pathlib import Path
p=argparse.ArgumentParser()
for arg in ['repository','revision','destination']: p.add_argument('--'+arg)
p.add_argument('--resume',action='store_true');a=p.parse_args()
r=Path(a.destination);r.mkdir(exist_ok=True)
(r/'pid').write_text(str(os.getpid()))
f=r/'payload';n=f.stat().st_size if a.resume and f.exists() else 0
print('PRIVATE secret path',flush=True);print('x'*100000,flush=True)
while n<100:
 n+=1;f.write_bytes(b'x'*n)
 print(json.dumps(dict(v=1,event='progress',bytes=n,total=100,speed=10)),flush=True)
 time.sleep(.02)
''');
    final d = NativeModelDownloader();
    final destination = '${root.path}/data';
    Future<void> run({bool resume = false}) => d.run(
      'python3',
      script.path,
      'owner/model',
      'sha',
      destination,
      resume: resume,
    );
    final first = expectLater(run(), throwsA(isA<DownloadInterrupted>()));
    await d.events
        .firstWhere((e) => e.bytes >= 3)
        .timeout(const Duration(seconds: 10));
    await d.interrupt(pause: true);
    await first;
    expect(
      await File('$destination/payload').length(),
      inInclusiveRange(3, 99),
    );
    expect(d.progress.phase, DownloadPhase.paused);
    final pid = int.parse(await File('$destination/pid').readAsString());
    expect(Process.killPid(pid, ProcessSignal.sigcont), isFalse);
    await run(resume: true);
    expect(await File('$destination/payload').length(), 100);
    expect(d.progress.phase, DownloadPhase.complete);
    final third = expectLater(run(), throwsA(isA<DownloadInterrupted>()));
    await d.events
        .firstWhere((e) => e.phase == DownloadPhase.downloading && e.bytes >= 2)
        .timeout(const Duration(seconds: 10));
    await d.interrupt(pause: false);
    await third;
    expect(d.progress.phase, DownloadPhase.stopped);
  }, skip: Platform.isWindows);
  test(
    'deadline and Stop bound inherited pipe cleanup after helper exit',
    () async {
      final root = await Directory.systemTemp.createTemp('asg inherited pipe ');
      addTearDown(() => root.delete(recursive: true));
      final script = File('${root.path}/pipe.py');
      await script.writeAsString('''import subprocess,sys,json
from pathlib import Path
child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(20)'])
Path('${root.path}/pid').write_text(str(child.pid))
print(json.dumps(dict(v=1,event='progress',bytes=1,total=10,speed=1)),flush=True)
''');
      Future<void> clean() async {
        final file = File('${root.path}/pid');
        if (await file.exists()) {
          Process.killPid(
            int.parse(await file.readAsString()),
            ProcessSignal.sigkill,
          );
        }
      }

      addTearDown(clean);
      final first = NativeModelDownloader();
      final result = expectLater(
        first.run(
          'python3',
          script.path,
          'owner/model',
          'pin',
          root.path,
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await result.timeout(const Duration(seconds: 3));
      expect(first.progress.phase, DownloadPhase.failed);
      await clean();
      final second = NativeModelDownloader();
      final stopped = expectLater(
        second.run('python3', script.path, 'owner/model', 'pin', root.path),
        throwsA(isA<DownloadInterrupted>()),
      );
      await second.events
          .firstWhere((e) => e.bytes == 1)
          .timeout(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await second.interrupt(pause: false).timeout(const Duration(seconds: 1));
      await stopped;
      expect(second.progress.phase, DownloadPhase.stopped);
    },
    skip: Platform.isWindows,
  );
  testWidgets('narrow enlarged text shows progress speed and usable controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var pauses = 0, stops = 0, resumes = 0;
    Future<void> show(ModelDownloadProgress p, bool busy) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: SingleChildScrollView(
              child: ModelDownloadPanel(
                progress: p,
                busy: busy,
                onPause: () => pauses++,
                onResume: () => resumes++,
                onStop: () => stops++,
              ),
            ),
          ),
        ),
      ),
    );
    await show(
      const ModelDownloadProgress(
        phase: DownloadPhase.downloading,
        bytes: 1024,
        total: 2048,
        bytesPerSecond: 512,
      ),
      true,
    );
    expect(find.text('1.0 KiB / 2.0 KiB · 50.0%'), findsOneWidget);
    expect(find.text('512 B/s'), findsOneWidget);
    await tester.tap(find.text('Pause download'));
    await tester.tap(find.text('Stop download'));
    expect(pauses, 1);
    expect(stops, 1);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Resume download'),
          )
          .onPressed,
      isNull,
    );
    await show(
      const ModelDownloadProgress(
        phase: DownloadPhase.paused,
        bytes: 1024,
        total: 2048,
      ),
      false,
    );
    await tester.tap(find.text('Resume download'));
    expect(resumes, 1);
    expect(tester.takeException(), isNull);
  });
}

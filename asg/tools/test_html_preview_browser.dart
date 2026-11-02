// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

// Actual macOS export/production-host/Chrome acceptance. No model inference,
// arbitrary source execution, stable app replacement or general adapter claim.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/services/html/html_preview_native.dart';
import 'package:asg/services/html/html_source_export_native.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class Protocol {
  Protocol(this.socket) {
    subscription = socket.listen((data) {
      final record = jsonDecode(data as String) as Map<String, dynamic>;
      final id = record['id'];
      if (id is int) {
        pending.remove(id)?.complete(record);
      } else if (record['method'] == 'Runtime.exceptionThrown' ||
          (record['method'] == 'Log.entryAdded' &&
              (record['params'] as Map)['entry']['level'] == 'error')) {
        errors.add(record);
      }
    });
  }
  final WebSocket socket;
  late final StreamSubscription<dynamic> subscription;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  final errors = <Object>[];
  int next = 0;
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final id = ++next;
    final completer = Completer<Map<String, dynamic>>();
    pending[id] = completer;
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    try {
      final response = await completer.future.timeout(
        const Duration(seconds: 10),
      );
      require(
        !response.containsKey('error'),
        'Browser protocol failed: $method',
      );
      return response['result'] as Map<String, dynamic>;
    } finally {
      pending.remove(id);
    }
  }

  Future<Object?> evaluate(String expression) async {
    final result = await call('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    require(
      !result.containsKey('exceptionDetails'),
      'Browser assertion: $result',
    );
    return (result['result'] as Map)['value'];
  }

  Future<void> close() async {
    await subscription.cancel();
    await socket.close();
  }
}

Future<void> main() async {
  require(
    Platform.isMacOS,
    'This acceptance requires macOS and installed Chrome.',
  );
  final chrome =
      Platform.environment['CHROME_EXECUTABLE'] ??
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  require(
    await File(chrome).exists(),
    'Installed Chrome required; no download.',
  );
  final temporary = await Directory.systemTemp.createTemp('asg-html-browser-');
  final parent = await temporary.resolveSymbolicLinks();
  final host = HtmlPreviewNative();
  Process? browser;
  Protocol? protocol;
  final client = HttpClient();
  try {
    final request = HtmlExportRequest(
      input: HtmlSiteInput(
        title: 'Browser & local preview',
        description: 'Actual fixed export',
      ),
      parent: parent,
      folderName: 'browser_site',
    );
    final directory = await HtmlSourceExportNative().export(
      request: request,
      confirmedRequest: request,
      authorizeWrite: () {},
    );
    final url = await host.start(directory: directory, input: request.input);
    browser = await Process.start(chrome, [
      '--headless',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--remote-debugging-port=0',
      '--user-data-dir=$parent/chrome',
      'about:blank',
    ]);
    unawaited(browser.stdout.drain<void>());
    unawaited(browser.stderr.drain<void>());
    final active = File('$parent/chrome/DevToolsActivePort');
    for (var i = 0; i < 100 && !await active.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final port = int.parse((await active.readAsLines()).first);
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/json/list'),
    )).close();
    final targets =
        jsonDecode(await utf8.decoder.bind(response).join()) as List;
    final page = targets.cast<Map>().firstWhere(
      (item) => item['type'] == 'page',
    );
    protocol = Protocol(
      await WebSocket.connect(page['webSocketDebuggerUrl'] as String),
    );
    await protocol.call('Runtime.enable');
    await protocol.call('Log.enable');
    await protocol.call('Page.enable');
    await protocol.call('Page.navigate', {'url': url.toString()});
    for (var i = 0; i < 100; i++) {
      if (await protocol.evaluate(
            "document.readyState === 'complete' && !!document.getElementById('theme-toggle') && !document.getElementById('theme-toggle').hidden",
          ) ==
          true) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    require(
      await protocol.evaluate('''(() => {
      const check = (v,m) => { if (!v) throw Error(m); };
      check(document.title === 'Browser & local preview', 'title');
      check(document.styleSheets.length === 1 && document.styleSheets[0].cssRules.length > 15, 'CSS');
      check([...document.images].every(i => i.complete && i.naturalWidth > 0), 'assets');
      const toggle = document.getElementById('theme-toggle');
      check(!toggle.hidden, 'JS'); toggle.focus(); check(document.activeElement === toggle, 'focus');
      toggle.click(); check(toggle.getAttribute('aria-pressed') === 'true', 'theme');
      check(getComputedStyle(document.documentElement).colorScheme === 'dark', 'theme CSS');
      toggle.click(); check(toggle.getAttribute('aria-pressed') === 'false', 'theme retry');
      document.querySelector('summary').click(); check(document.querySelector('details').open, 'details');
      document.querySelector('nav a').click(); check(location.hash === '#overview', 'navigation');
      return true;
    })()''') ==
          true,
      'Browser interactions',
    );
    await protocol.evaluate("document.getElementById('theme-toggle').focus()");
    for (final type in ['keyDown', 'keyUp']) {
      await protocol.call('Input.dispatchKeyEvent', {
        'type': type,
        'key': ' ',
        'code': 'Space',
        'windowsVirtualKeyCode': 32,
      });
    }
    require(
      await protocol.evaluate(
            "document.getElementById('theme-toggle').getAttribute('aria-pressed') === 'true'",
          ) ==
          true,
      'Keyboard Space activates theme',
    );
    for (final width in [320, 1280]) {
      await protocol.call('Emulation.setDeviceMetricsOverride', {
        'width': width,
        'height': 900,
        'deviceScaleFactor': 1,
        'mobile': false,
      });
      for (final scale in ['100%', '200%']) {
        require(
          await protocol.evaluate('''(() => {
          document.documentElement.style.fontSize = '$scale';
          const cards = document.querySelectorAll('article');
          const a = cards[0].getBoundingClientRect(), b = cards[1].getBoundingClientRect();
          return innerWidth === $width && document.documentElement.scrollWidth <= document.documentElement.clientWidth && ($width === 320 ? b.top > a.top : b.left > a.left);
        })()''') ==
              true,
          'Layout $width / $scale',
        );
      }
    }
    require(
      protocol.errors.isEmpty,
      'Browser console/resource errors: ${protocol.errors}',
    );
    await host.stop();
    var stopped = false;
    try {
      await (await client.getUrl(url)).close();
    } on SocketException {
      stopped = true;
    }
    require(stopped, 'Stop must close owned HTTP host.');
    final retry = await host.start(directory: directory, input: request.input);
    require(retry != url, 'Retry must establish a new URL.');
    final retried = await (await client.getUrl(retry)).close();
    require(retried.statusCode == 200, 'Retry response');
    await retried.drain<void>();
    // Exercise the real OS launcher, without equating exit success to visible UI.
    await host.open();
    stdout.writeln(
      'PASS: real export/production preview, Chrome assets/console/focus/theme/details/navigation, 320/1280px and 2x text, Stop/retry. OS browser launch request accepted; visible default-browser state not asserted.',
    );
  } finally {
    await host.stop();
    await protocol?.close();
    client.close(force: true);
    if (browser != null) {
      browser.kill();
      await browser.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          browser?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    // Chrome descendants may still be relinquishing their profile; retain it
    // if cleanup is contested rather than deleting anything outside this root.
    try {
      await temporary.delete(recursive: true);
    } on FileSystemException {
      stderr.writeln('Disposable browser profile retained: ${temporary.path}');
    }
  }
}

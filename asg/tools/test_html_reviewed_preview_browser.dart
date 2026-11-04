// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

// Actual production passive host and installed Chrome; fixture source only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/services/html/html_preview_host_native.dart';

import 'test_html_preview_browser.dart' show Protocol, require;

Future<void> main() async {
  require(Platform.isMacOS, 'macOS required');
  final chrome =
      Platform.environment['CHROME_EXECUTABLE'] ??
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  require(await File(chrome).exists(), 'Installed Chrome required');
  final temporary = await Directory.systemTemp.createTemp(
    'asg-passive-browser-',
  );
  final parent = await temporary.resolveSymbolicLinks();
  final directory = await Directory('$parent/site').create();
  final source = HtmlSourceProposal.decode(
    jsonEncode({
      'summary': 'Passive fixture',
      'files': {
        'index.html': '<!doctype html><title>Passive</title><meta name="viewport" content="width=device-width"><link rel="stylesheet" href="styles.css"><h1>Passive</h1><script>document.body.dataset.ran="inline"</script><script src="app.js"></script><form action="/sent"><input name="message"><button>Send</button></form>',
        'styles.css':
            'h1 { color: rgb(0, 128, 0); } body { overflow-wrap: anywhere; }',
        'app.js': 'document.body.dataset.ran="external";',
      },
    }),
  );
  for (final e in source.files.entries) {
    await File('${directory.path}/${e.key}').writeAsString(e.value);
  }
  final host = HtmlPreviewHostNative();
  final client = HttpClient();
  Process? browser;
  Protocol? protocol;
  try {
    final url = await host.startReviewed(
      directory: directory.path,
      proposal: source,
      authorizeRead: () {},
    );
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
    final page = targets.cast<Map>().firstWhere((e) => e['type'] == 'page');
    protocol = Protocol(
      await WebSocket.connect(page['webSocketDebuggerUrl'] as String),
    );
    await protocol.call('Runtime.enable');
    await protocol.call('Log.enable');
    await protocol.call('Page.enable');
    await protocol.call('Page.navigate', {'url': url.toString()});
    for (var i = 0; i < 100; i++) {
      if (await protocol.evaluate(
            "document.readyState === 'complete' && document.title === 'Passive'",
          ) ==
          true) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    require(
      await protocol.evaluate(
            "getComputedStyle(document.querySelector('h1')).color",
          ) ==
          'rgb(0, 128, 0)',
      'External CSS must actually render',
    );
    require(
      await protocol.evaluate("document.body.dataset.ran === undefined") ==
          true,
      'Inline/external scripts must not run',
    );
    require(
      await protocol.evaluate(
            "(() => { try { localStorage.setItem('x','x'); return false; } catch (_) { return true; } })()",
          ) ==
          true,
      'Sandbox must have opaque origin',
    );
    await protocol.evaluate("document.querySelector('form').submit()");
    await Future<void>.delayed(const Duration(milliseconds: 100));
    require(
      await protocol.evaluate('location.href') == url.toString(),
      'Forms must not navigate',
    );
    for (final width in [320, 1280]) {
      await protocol.call('Emulation.setDeviceMetricsOverride', {
        'width': width,
        'height': 800,
        'deviceScaleFactor': 1,
        'mobile': false,
      });
      require(
        await protocol.evaluate(
              'document.documentElement.scrollWidth <= innerWidth',
            ) ==
            true,
        'Fixture must fit viewport',
      );
    }
    require(
      protocol.errors.any((e) => e.toString().contains('script')),
      'Observe actual script refusal',
    );
    await host.stop();
    require(host.url == null, 'Stop must clear URL');
    stdout.writeln(
      'PASS: production passive preview CSS at 320/1280px, inline/external script refusal, opaque sandbox origin, form refusal and Stop. No model/interactive-adapter acceptance claim.',
    );
  } finally {
    await protocol?.close();
    await host.stop();
    client.close(force: true);
    browser?.kill();
    if (browser != null) {
      await browser.exitCode.timeout(const Duration(seconds: 10));
    }
    // Browser descendants can retain their owned profile briefly; keep receipts.
  }
}

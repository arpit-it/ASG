// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/services/html/html_preview_host_native.dart';
import 'package:flutter_test/flutter_test.dart';

HtmlSourceProposal source() => HtmlSourceProposal.decode(
  jsonEncode({
    'summary': 'Passive site',
    'files': {
      'index.html': '<!doctype html><link rel="stylesheet" href="styles.css"><h1>Passive</h1><script>document.body.dataset.ran="yes"</script><script src="app.js"></script>',
      'styles.css': 'h1 { color: rgb(0, 128, 0); }',
      'app.js': 'document.body.dataset.ran="yes";',
    },
  }),
);

void main() {
  group('actual passive host', () {
    late Directory root;
    late HtmlPreviewHostNative host;
    late HttpClient client;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('asg_passive_');
      root = Directory(await root.resolveSymbolicLinks());
      for (final e in source().files.entries) {
        await File('${root.path}/${e.key}').writeAsString(e.value);
      }
      host = HtmlPreviewHostNative();
      client = HttpClient();
    });
    tearDown(() async {
      client.close(force: true);
      await host.stop();
      await root.delete(recursive: true);
    });
    Future<HttpClientResponse> get(
      Uri url, {
      String method = 'GET',
      String? foreignHost,
    }) async {
      final request = await client.openUrl(method, url);
      if (foreignHost != null) request.headers.set('host', foreignHost);
      return request.close();
    }

    test(
      'exact immutable bytes, passive policy, routes, methods and revocation',
      () async {
        var fresh = true;
        final url = await host.startReviewed(
          directory: root.path,
          proposal: source(),
          authorizeRead: () {
            if (!fresh) throw StateError('stale');
          },
        );
        final response = await get(url);
        expect(response.statusCode, 200);
        final csp = response.headers.value('content-security-policy')!;
        expect(csp, contains("script-src 'none'"));
        expect(csp, startsWith('sandbox;'));
        expect(csp, contains("form-action 'none'"));
        expect(csp, contains("connect-src 'none'"));
        expect(
          await utf8.decoder.bind(response).join(),
          source().files['index.html'],
        );
        await File('${root.path}/styles.css').writeAsString('changed');
        final css = await get(url.resolve('styles.css'));
        expect(
          await utf8.decoder.bind(css).join(),
          source().files['styles.css'],
        );
        for (final relative in [
          'app.js',
          'styles.css?x',
          'styles.css%2f',
          '../',
          'README.md',
        ]) {
          final result = await get(url.resolve(relative));
          expect(result.statusCode, 404);
          await result.drain<void>();
        }
        for (final method in ['POST', 'PUT', 'OPTIONS']) {
          final result = await get(url, method: method);
          expect(result.statusCode, 403);
          await result.drain<void>();
        }
        final foreign = await get(url, foreignHost: 'localhost');
        expect(foreign.statusCode, 403);
        await foreign.drain<void>();
        final head = await get(url, method: 'HEAD');
        expect(head.statusCode, 200);
        expect(await head.toList(), isEmpty);
        fresh = false;
        final stale = await get(url);
        expect(stale.statusCode, 403);
        await stale.drain<void>();
        await host.stop();
        expect(host.url, isNull);
      },
    );
    test(
      'changed missing symbolic and extra files refuse before binding',
      () async {
        for (final kind in ['changed', 'missing', 'symbolic', 'extra']) {
          final css = File('${root.path}/styles.css');
          if (await FileSystemEntity.isLink(css.path)) {
            await Link(css.path).delete();
          } else if (await css.exists()) {
            await css.delete();
          }
          await css.writeAsString(source().files['styles.css']!);
          if (kind == 'changed') await css.writeAsString('changed');
          if (kind == 'missing') await css.delete();
          if (kind == 'symbolic') {
            await css.delete();
            await Link(css.path).create('${root.path}/app.js');
          }
          if (kind == 'extra') {
            await File('${root.path}/extra').writeAsString('extra');
          }
          await expectLater(
            host.startReviewed(
              directory: root.path,
              proposal: source(),
              authorizeRead: () {},
            ),
            throwsFormatException,
          );
          expect(host.url, isNull);
        }
      },
    );
    test(
      'Stop during an actual read prevents publication and permits retry',
      () async {
        var stopped = false;
        await expectLater(
          host.startReviewed(
            directory: root.path,
            proposal: source(),
            authorizeRead: () {
              if (!stopped) {
                stopped = true;
                host.stop();
              }
            },
          ),
          throwsStateError,
        );
        expect(host.url, isNull);
        await host.startReviewed(
          directory: root.path,
          proposal: source(),
          authorizeRead: () {},
        );
        expect(host.url, isNotNull);
      },
    );
    test('revoked startup binds nothing and can retry', () async {
      await expectLater(
        host.startReviewed(
          directory: root.path,
          proposal: source(),
          authorizeRead: () {
            throw StateError('revoked');
          },
        ),
        throwsStateError,
      );
      expect(host.url, isNull);
      final url = await host.startReviewed(
        directory: root.path,
        proposal: source(),
        authorizeRead: () {},
      );
      expect(url.host, '127.0.0.1');
      await expectLater(
        host.startReviewed(
          directory: root.path,
          proposal: source(),
          authorizeRead: () {},
        ),
        throwsStateError,
      );
    });
  }, skip: !Platform.isMacOS);
}

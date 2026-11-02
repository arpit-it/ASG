// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/services/html/html_preview_host_native.dart';
import 'package:asg/services/html/html_site_template.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fixed HTML native preview host', () {
    late Directory directory;
    late HtmlPreviewHostNative host;
    final input = HtmlSiteInput(
      title: 'Preview & test',
      description: 'Local only',
    );
    setUp(() async {
      final temporary = await Directory.systemTemp.createTemp(
        'asg-html-preview-',
      );
      directory = Directory(await temporary.resolveSymbolicLinks());
      for (final entry in HtmlSiteTemplate().generate(input).entries) {
        final file = File('${directory.path}/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value);
      }
      host = HtmlPreviewHostNative();
    });
    tearDown(() async {
      await host.stop();
      await directory.delete(recursive: true);
    });
    test(
      'serves exact snapshot, MIME/security headers, HEAD and stops sockets',
      () async {
        final url = await host.start(directory: directory.path, input: input);
        expect(url.host, '127.0.0.1');
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        for (final entry in HtmlSiteTemplate().generate(input).entries) {
          if (entry.key == 'README.md') continue;
          final response = await (await client.getUrl(url.resolve(entry.key)))
              .close();
          expect(response.statusCode, 200);
          expect(response.headers.value('cache-control'), 'no-store');
          expect(
            response.headers.value('content-security-policy'),
            contains("connect-src 'none'"),
          );
          expect(response.headers.value('x-content-type-options'), 'nosniff');
          expect(await utf8.decoder.bind(response).join(), entry.value);
        }
        final head = await (await client.openUrl('HEAD', url)).close();
        expect(head.statusCode, 200);
        expect(await head.fold<int>(0, (n, bytes) => n + bytes.length), 0);
        await File('${directory.path}/index.html').writeAsString('changed');
        final retained = await (await client.getUrl(url)).close();
        expect(
          await utf8.decoder.bind(retained).join(),
          contains('Preview &amp; test'),
        );
        await expectLater(
          host.start(directory: directory.path, input: input),
          throwsStateError,
        );
        await host.stop();
        expect(host.url, isNull);
        await expectLater(client.getUrl(url), throwsA(isA<SocketException>()));
        expect(
          await File('${directory.path}/index.html').readAsString(),
          'changed',
        );
      },
    );
    test(
      'refuses methods, foreign hosts/origins, paths and cross-site fetches',
      () async {
        final url = await host.start(directory: directory.path, input: input);
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        Future<void> refused(
          Uri uri, {
          String method = 'GET',
          Map<String, String> headers = const {},
        }) async {
          final request = await client.openUrl(method, uri);
          headers.forEach(request.headers.set);
          final response = await request.close();
          expect(response.statusCode, anyOf(403, 404));
          await response.drain<void>();
        }

        await refused(url, method: 'POST');
        await refused(url, headers: {'host': 'attacker.example'});
        await refused(url, headers: {'origin': 'https://attacker.example'});
        await refused(
          url,
          headers: {'sec-fetch-site': 'cross-site', 'sec-fetch-mode': 'cors'},
        );
        for (final relative in [
          'README.md',
          'missing',
          '../index.html',
          'assets/',
          'assets%2fmark.svg',
          'index.html?x=1',
        ]) {
          await refused(url.resolve(relative));
        }
        await refused(url.replace(path: '/'));
      },
    );
    test('rejects missing, changed, oversize and linked sources; retry is explicit', () async {
      final file = File('${directory.path}/app.js');
      final original = await file.readAsString();
      for (final replacement in ['', 'bad', List.filled(1000000, 'x').join()]) {
        await file.writeAsString(replacement);
        await expectLater(
          host.start(directory: directory.path, input: input),
          throwsFormatException,
        );
        expect(host.url, isNull);
        expect(host.starting, false);
      }
      await file.delete();
      await expectLater(
        host.start(directory: directory.path, input: input),
        throwsFormatException,
      );
      final other = File('${directory.path}/other.js');
      await other.writeAsString(original);
      await Link(file.path).create(other.path);
      await expectLater(
        host.start(directory: directory.path, input: input),
        throwsFormatException,
      );
      await Link(file.path).delete();
      await file.writeAsString(original);
      expect(
        await host.start(directory: directory.path, input: input),
        host.url,
      );
    });
    test('rejects wrong input and symbolic directory/asset parents', () async {
      await expectLater(
        host.start(
          directory: directory.path,
          input: HtmlSiteInput(title: 'Different', description: 'Local only'),
        ),
        throwsFormatException,
      );
      final link = Link('${directory.path}_link');
      await link.create(directory.path);
      try {
        await expectLater(
          host.start(directory: link.path, input: input),
          throwsFormatException,
        );
      } finally {
        await link.delete();
      }
      final assets = Directory('${directory.path}/assets');
      await assets.rename('${directory.path}/real_assets');
      await Link(assets.path).create('${directory.path}/real_assets');
      await expectLater(
        host.start(directory: directory.path, input: input),
        throwsFormatException,
      );
    });
    test(
      'Stop during startup revokes publication and permits later restart',
      () async {
        final operation = host.start(directory: directory.path, input: input);
        expect(host.starting, true);
        await expectLater(
          host.start(directory: directory.path, input: input),
          throwsStateError,
        );
        await host.stop();
        await expectLater(operation, throwsStateError);
        expect(host.url, isNull);
        expect(host.starting, false);
        final url = await host.start(directory: directory.path, input: input);
        expect(host.url, url);
        await host.stop();
        await host.stop();
      },
    );
  }, skip: !Platform.isMacOS);
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import '../../models/html/html_site_input.dart';
import 'html_site_template.dart';

/// Read-only preview of an exact, unmodified fixed starter export on macOS.
/// Serves an immutable snapshot, never arbitrary edited source or filesystem
/// requests. No process, model, dependency installation or browser is launched.
/// Callers own Stop/disposal. This is not a hostile-filesystem sandbox.
class HtmlPreviewHostNative {
  HttpServer? _server;
  Uri? _url;
  bool _starting = false;
  int _generation = 0;

  Uri? get url => _url;
  bool get starting => _starting;

  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
  }) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('Fixed HTML preview requires macOS.');
    }
    if (_starting || _server != null) {
      throw StateError(
        'Stop the current HTML preview before starting another.',
      );
    }
    _starting = true;
    final generation = ++_generation;
    void check() {
      if (generation != _generation) {
        throw StateError('HTML preview startup was stopped.');
      }
    }

    HttpServer? bound;
    try {
      if (!path.isAbsolute(directory) ||
          await Directory(directory).resolveSymbolicLinks() !=
              path.normalize(directory)) {
        throw const FormatException('Choose a real absolute export directory.');
      }
      final sources = HtmlSiteTemplate().generate(input);
      final snapshot = <String, List<int>>{};
      for (final entry in sources.entries) {
        check();
        final file = File(path.join(directory, entry.key));
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await file.resolveSymbolicLinks() != file.path) {
          throw const FormatException('Export file is missing or symbolic.');
        }
        final expected = utf8.encode(entry.value);
        // Bound reads even if the file grows after inspection; do not load an
        // arbitrary file into memory. Exact bytes bind preview to this input.
        final reader = await file.open();
        late List<int> bytes;
        try {
          bytes = await reader.read(expected.length + 1);
        } finally {
          await reader.close();
        }
        if (bytes.length != expected.length ||
            !Iterable<int>.generate(bytes.length)
                .every((index) => bytes[index] == expected[index])) {
          throw const FormatException(
            'Export changed. Only the exact fixed starter can be previewed.',
          );
        }
        if (entry.key != 'README.md') snapshot[entry.key] = bytes;
      }
      check();
      bound = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      check();
      final server = bound;
      final token = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final origin = 'http://127.0.0.1:${server.port}';
      final url = Uri.parse('$origin/$token/');
      server.idleTimeout = const Duration(seconds: 5);
      server.listen((request) async {
        final response = request.response;
        try {
          response.persistentConnection = false;
          response.headers.set('Cache-Control', 'no-store');
          response.headers.set('X-Content-Type-Options', 'nosniff');
          response.headers.set('Referrer-Policy', 'no-referrer');
          response.headers.set(
            'Content-Security-Policy',
            "default-src 'none'; script-src 'self'; style-src 'self'; "
                "img-src 'self'; base-uri 'none'; frame-ancestors 'none'; "
                "form-action 'none'; connect-src 'none'",
          );
          final site = request.headers.value('sec-fetch-site');
          final requestOrigin = request.headers.value('origin');
          if (generation != _generation ||
              !['GET', 'HEAD'].contains(request.method) ||
              request.headers.value('host') != '127.0.0.1:${server.port}' ||
              (requestOrigin != null && requestOrigin != origin) ||
              (site == 'cross-site' &&
                  !(request.headers.value('sec-fetch-mode') == 'navigate' &&
                      request.headers.value('sec-fetch-dest') == 'document')) ||
              request.contentLength > 0 ||
              request.headers.chunkedTransferEncoding) {
            response.statusCode = HttpStatus.forbidden;
            return;
          }
          // Exact URI allowlist excludes query strings, encoded separators,
          // traversal, absolute request targets, README and directory listings.
          final targets = <String, String>{
            '/$token/': 'index.html',
            for (final name in snapshot.keys) '/$token/$name': name,
          };
          final name = targets[request.uri.toString()];
          if (name == null) {
            response.statusCode = HttpStatus.notFound;
            return;
          }
          final bytes = snapshot[name]!;
          response.headers.contentType = ContentType.parse(switch (name) {
            'index.html' => 'text/html; charset=utf-8',
            'styles.css' => 'text/css; charset=utf-8',
            'app.js' => 'application/javascript; charset=utf-8',
            _ => 'image/svg+xml',
          });
          response.contentLength = bytes.length;
          if (request.method == 'GET') response.add(bytes);
        } catch (_) {
          // Disconnects and malformed requests must not escape the listener.
        } finally {
          await response.close().catchError((Object _) {});
        }
      }, onError: (Object _) {});
      _server = server;
      _url = url;
      return url;
    } catch (_) {
      await bound?.close(force: true);
      rethrow;
    } finally {
      _starting = false;
    }
  }

  /// Revokes startup and closes owned sockets. Exported files are untouched.
  /// If startup is reading files, it observes revocation before publication.
  Future<void> stop() async {
    _generation++;
    final server = _server;
    _server = null;
    _url = null;
    await server?.close(force: true);
  }
}

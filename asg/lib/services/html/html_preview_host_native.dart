// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../models/html/html_site_input.dart';
import '../../models/html/html_source_proposal.dart';
import 'html_reviewed_source_check_native.dart';
import 'html_starter_snapshot_native.dart';

/// Read-only preview of a fixed starter or explicitly confirmed passive proposal.
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
    void Function()? authorizeRead,
  }) async {
    return _start(
      authorizeRead: authorizeRead,
      read: (check) => readHtmlStarterSnapshot(
        directory: directory,
        input: input,
        check: check,
      ),
    );
  }

  /// Explicitly confirmed passive preview. Export identity is checked before
  /// binding; served bytes come only from the immutable reviewed proposal.
  Future<Uri> startReviewed({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  }) => _start(
    passive: true,
    authorizeRead: authorizeRead,
    read: (check) async {
      await NativeHtmlReviewedSourceChecker().check(
        directory: directory,
        proposal: proposal,
        authorizeRead: check,
      );
      check();
      return {
        for (final file in proposal.files.entries)
          if (file.key != 'app.js') file.key: utf8.encode(file.value),
      };
    },
  );

  Future<Uri> _start({
    required Future<Map<String, List<int>>> Function(void Function()) read,
    void Function()? authorizeRead,
    bool passive = false,
  }) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('HTML preview requires macOS.');
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
      authorizeRead?.call();
    }

    HttpServer? bound;
    try {
      final snapshot = await read(check);
      snapshot.remove('README.md');
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
          // Retained consent is rechecked for every request, including HEAD.
          // Already-dispatched responses cannot be recalled.
          try {
            check();
          } catch (_) {
            response.statusCode = HttpStatus.forbidden;
            return;
          }
          response.persistentConnection = false;
          response.headers.set('Cache-Control', 'no-store');
          response.headers.set('X-Content-Type-Options', 'nosniff');
          response.headers.set('Referrer-Policy', 'no-referrer');
          response.headers.set(
            'Content-Security-Policy',
            passive
                ? "sandbox; default-src 'none'; script-src 'none'; "
                      "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                      "base-uri 'none'; frame-ancestors 'none'; form-action 'none'; "
                      "connect-src 'none'; object-src 'none'"
                : "default-src 'none'; script-src 'self'; style-src 'self'; "
                      "img-src 'self'; base-uri 'none'; frame-ancestors 'none'; "
                      "form-action 'none'; connect-src 'none'",
          );
          final site = request.headers.value('sec-fetch-site');
          final requestOrigin = request.headers.value('origin');
          // CSP sandbox gives the passive document an opaque origin. Its own
          // stylesheet is therefore a cross-site no-cors subresource. The exact
          // secret-token route allowlist still applies; no scripts are served.
          final passiveStyle =
              passive &&
              request.headers.value('sec-fetch-dest') == 'style' &&
              request.headers.value('sec-fetch-mode') == 'no-cors';
          if (generation != _generation ||
              !['GET', 'HEAD'].contains(request.method) ||
              request.headers.value('host') != '127.0.0.1:${server.port}' ||
              (requestOrigin != null &&
                  requestOrigin != origin &&
                  !(passiveStyle && requestOrigin == 'null')) ||
              (site == 'cross-site' &&
                  !passiveStyle &&
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

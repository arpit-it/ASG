// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('vm')
library;

import 'dart:io';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/runtime_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime health refuses redirects and a direct retry works', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => source.close(force: true));
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => target.close(force: true));
    final connection = RuntimeConnection();
    addTearDown(connection.close);
    final config = LocalModelConfig(
      baseUrl: 'http://127.0.0.1:${source.port}/v1',
    );
    final location = 'http://127.0.0.1:${target.port}/private-target';
    var targetRequests = 0;
    target.listen((request) async {
      targetRequests++;
      request.response.write(
        '{"status":"ready","phase":"idle","model":"redirected"}',
      );
      await request.response.close();
    });

    var status = HttpStatus.movedPermanently;
    source.listen((request) async {
      expect(request.method, 'GET');
      expect(request.uri.path, '/health');
      request.response.statusCode = status;
      if (status == HttpStatus.ok) {
        request.response.write(
          '{"status":"ready","phase":"idle","model":"configured"}',
        );
      } else {
        request.response.headers.set(HttpHeaders.locationHeader, location);
        request.response.write('private-body');
      }
      await request.response.close();
    });

    for (final code in [301, 302, 303, 307, 308]) {
      status = code;
      final health = await connection.check(config);
      expect(
        targetRequests,
        0,
        reason: 'HTTP $code must not contact the target',
      );
      expect(health.ready, isFalse);
      expect(health.idle, isFalse);
      expect(health.model, isNull);
      expect(health.detail, isNot(contains('private-')));
    }

    status = HttpStatus.ok;
    final health = await connection.check(config);
    expect(health.ready, isTrue);
    expect(health.idle, isTrue);
    expect(health.model, 'configured');
    expect(targetRequests, 0);
  });

  test('runtime health caps declared and chunked successful bodies', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final connection = RuntimeConnection();
    addTearDown(connection.close);
    final config = LocalModelConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
    );

    const limit = 64 * 1024;
    const prefix = '{"status":"ready","model":"configured","padding":"';
    const suffix = '"}';
    var size = limit;
    var chunked = false;
    server.listen((request) async {
      final response = request.response;
      if (!chunked) response.contentLength = size;
      final padding = 'x' * (size - prefix.length - suffix.length);
      response.write(prefix);
      response.write(padding.substring(0, padding.length ~/ 2));
      if (chunked) await response.flush();
      response.write(padding.substring(padding.length ~/ 2));
      response.write(suffix);
      await response.close();
    });

    final atLimit = await connection.check(config);
    expect(atLimit.ready, isTrue);
    expect(atLimit.model, 'configured');

    size = limit + 1;
    for (final useChunked in [false, true]) {
      chunked = useChunked;
      final oversized = await connection.check(config);
      expect(oversized.ready, isFalse, reason: 'chunked: $useChunked');
      expect(oversized.model, isNull);
      expect(oversized.detail, contains('invalid'));
      expect(oversized.detail, isNot(contains('configured')));
    }
    size = limit;
    expect((await connection.check(config)).ready, isTrue);
  });

  test('runtime health reports HTTP failure with a stalled body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final connection = RuntimeConnection();
    addTearDown(connection.close);
    final config = LocalModelConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
    );
    var fail = true;
    server.listen((request) async {
      final response = request.response;
      if (fail) {
        response.statusCode = HttpStatus.serviceUnavailable;
        response.bufferOutput = false;
        response.write('private-sentinel');
        await response.flush();
        return;
      }
      response.write('{"status":"ready","phase":"idle","model":"configured"}');
      await response.close();
    });

    final failed = await connection.check(config);
    expect(failed.ready, isFalse);
    expect(failed.detail, contains('did not respond successfully'));
    expect(failed.detail, isNot(contains('private-sentinel')));

    fail = false;
    expect((await connection.check(config)).model, 'configured');
  });

  test('runtime health deadline includes a stalled response body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final connection = RuntimeConnection();
    addTearDown(connection.close);
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.write('{"status":"ready",');
      await request.response.flush();
    });

    final health = await connection.check(
      LocalModelConfig(baseUrl: 'http://127.0.0.1:${server.port}/v1'),
    );
    expect(health.ready, isFalse);
    expect(health.detail, contains('timed out after 3 seconds'));
  });
}

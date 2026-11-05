// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/html/html_export_request.dart';
import '../services/html/html_preview.dart';
import 'base_controller.dart';

class HtmlPreviewController extends BaseController {
  HtmlPreviewController(
    this.service, {
    this.deadline = const Duration(seconds: 10),
  }) : assert(deadline > Duration.zero);
  final HtmlPreview service;
  final Duration deadline;
  Uri? _url;
  String? _error, _notice;
  bool _starting = false,
      _stopping = false,
      _opening = false,
      _cleanupFailed = false;
  int _generation = 0;
  Uri? get url => _url;
  String? get error => _error;
  String? get notice => _notice;
  bool get supported => service.supported;
  bool get cleanupFailed => _cleanupFailed;
  bool get starting => _starting;
  bool get stopping => _stopping;
  bool get opening => _opening;
  bool get busy => _starting || _stopping || _opening;

  Future<void> start(String directory, HtmlExportRequest request) async {
    if (isDisposed || !supported || busy || _cleanupFailed || _url != null) {
      return;
    }
    final generation = ++_generation;
    _starting = true;
    _error = _notice = null;
    update();
    final timer = Timer(deadline, () {
      if (!isDisposed && _starting && generation == _generation) {
        unawaited(
          stop().then((_) {
            if (!isDisposed && !_cleanupFailed) {
              _error = 'Preview startup reached its deadline. Pending file IO may still settle; retry after cleanup finishes.';
              update();
            }
          }),
        );
      }
    });
    try {
      if (isDisposed || generation != _generation) return;
      final url = await service.start(
        directory: directory,
        input: request.input,
      );
      if (isDisposed || generation != _generation) {
        try {
          await service.stop();
        } catch (_) {
          if (!isDisposed) {
            _cleanupFailed = true;
            _error = 'Preview cleanup failed. Retry Stop before opening another preview.';
          }
        }
      } else {
        _url = url;
      }
    } catch (_) {
      // A failed startup may retain a bound preview or failed late cleanup.
      // Revoke authority and retain Stop retry before permitting redispatch.
      try {
        await service.stop();
      } catch (_) {
        if (!isDisposed) {
          _cleanupFailed = true;
          _notice = null;
          _error = 'Preview cleanup failed. Retry Stop before opening another preview.';
        }
      }
      if (!isDisposed && generation == _generation) {
        _error = _cleanupFailed
            ? 'Preview cleanup failed. Retry Stop before opening another preview.'
            : 'Preview could not start. Only unchanged fixed starter files with any required current Plan consent are allowed. Check the files and consent, then retry.';
      }
    } finally {
      timer.cancel();
      _starting = false;
      update();
    }
  }

  Future<void> open() async {
    if (isDisposed || busy || _url == null) return;
    final generation = _generation;
    _opening = true;
    _error = _notice = null;
    update();
    final timer = Timer(deadline, () {
      if (isDisposed || generation != _generation || !_opening) return;
      // Revoke preview authority without releasing the pending launch owner.
      // A browser already dispatched outside ASG cannot be recalled.
      unawaited(stop());
      _error = 'Browser launch deadline reached. Waiting for the launch request to return. An already-launched browser cannot be recalled.';
      update();
    });
    try {
      if (isDisposed || generation != _generation || _url == null) return;
      await service.open();
      if (!isDisposed && generation == _generation) {
        _notice =
            'Browser launch requested. Check the browser to confirm it opened.';
      }
    } catch (_) {
      if (!isDisposed && generation == _generation) {
        _error = 'Browser launch failed or timed out. Retry Open in browser or use the displayed local URL.';
      }
    } finally {
      timer.cancel();
      _error = _error?.replaceFirst(
        'Waiting for the launch request to return.',
        'The launch request has returned.',
      );
      _opening = false;
      update();
    }
  }

  Future<void> stop() async {
    if (isDisposed || _stopping) return;
    _generation++;
    _stopping = true;
    _url = null;
    _error = _notice = null;
    update();
    try {
      await service.stop();
      if (!isDisposed) _cleanupFailed = false;
      if (!isDisposed) _notice = 'Preview stopped. Exported files were retained. An already-dispatched browser launch may finish.';
    } catch (_) {
      if (!isDisposed) _cleanupFailed = true;
      if (!isDisposed) _error = 'Preview cleanup failed. Retry Stop before opening another preview.';
    } finally {
      _stopping = false;
      update();
    }
  }

  @override
  void dispose() {
    _generation++;
    _url = null;
    // Native stop revokes authority synchronously before its first await.
    unawaited(service.stop().catchError((Object _) {}));
    super.dispose();
  }
}

// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:path/path.dart' as path;

import '../../models/html/html_export_request.dart';
import '../generation_process_capture.dart';
import 'html_site_template.dart';
import 'html_source_export.dart';

/// Fixed or explicitly confirmed reviewed-source export; no shell,
/// verification, registration, promotion or preview. Source is never executed.
/// The caller owns confirmation and must revalidate current session authority
/// in [authorizeWrite]. This is not a sandbox against concurrent local actors.
/// An already-dispatched mutation may finish. Uncertain directory dispatches
/// report their destination, and unconfirmed child exits block further export.
class HtmlSourceExportNative
    implements HtmlSourceExport, HtmlReviewedSourceExport {
  HtmlSourceExportNative({
    Future<Process> Function(String directory)? startDirectoryProcess,
  }) : _startDirectoryProcess = startDirectoryProcess ?? _startDirectory;

  final Future<Process> Function(String) _startDirectoryProcess;
  final Map<int, Process> _unconfirmedProcesses = {};
  List<int> get pendingDirectoryProcessIds =>
      List.unmodifiable(_unconfirmedProcesses.keys);

  static Future<Process> _startDirectory(String directory) =>
      Process.start('/bin/mkdir', ['-m', '700', directory], runInShell: false);

  @override
  bool get supported => Platform.isMacOS;

  @override
  Future<String> export({
    required HtmlExportRequest request,
    required HtmlExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) => _exportSources(
    parentPath: request.parent,
    folderName: request.folderName,
    confirmed: confirmedRequest != null && request.matches(confirmedRequest),
    sources: HtmlSiteTemplate().generate(request.input),
    authorizeWrite: authorizeWrite,
  );

  @override
  Future<String> exportReviewed({
    required HtmlReviewedExportRequest request,
    required HtmlReviewedExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) => _exportSources(
    parentPath: request.parent,
    folderName: request.folderName,
    confirmed: confirmedRequest != null && request.matches(confirmedRequest),
    sources: request.proposal.files,
    authorizeWrite: authorizeWrite,
  );

  Future<String> _exportSources({
    required String parentPath,
    required String folderName,
    required bool confirmed,
    required Map<String, String> sources,
    required void Function() authorizeWrite,
  }) async {
    void check() {
      if (!supported) {
        throw UnsupportedError(
          'HTML source export is available on macOS only.',
        );
      }
      if (!confirmed) {
        throw StateError(
          'Confirm the exact HTML content and destination first.',
        );
      }
      if (_unconfirmedProcesses.isNotEmpty) {
        throw StateError(
          'A previous folder process has not exited; export is blocked.',
        );
      }
      authorizeWrite();
    }

    check();
    if (!path.isAbsolute(parentPath) ||
        !RegExp(r'^[a-z][a-z0-9_]{2,50}$').hasMatch(folderName)) {
      throw const FormatException(
        'Choose an absolute parent and a new 3–51 character lowercase folder name.',
      );
    }
    final parent = await Directory(parentPath).resolveSymbolicLinks();
    if (parent != path.normalize(parentPath)) {
      throw const FormatException('Choose a real parent, not a symbolic link.');
    }
    final destination = path.join(parent, folderName);
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('Destination already exists; nothing was overwritten.');
    }
    check();
    // Unlike Directory.create, mkdir refuses an existing directory atomically.
    Process? directoryProcess;
    int directoryExit;
    try {
      directoryProcess = await _startDirectoryProcess(destination);
      final captured = await captureGenerationProcess(
        directoryProcess,
        timeout: const Duration(seconds: 5),
      );
      directoryExit = captured.exitCode;
    } catch (_) {
      int? pendingPid;
      if (directoryProcess != null) {
        final process = directoryProcess;
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {
          // Retain ownership and refuse another export until exit is observed.
          pendingPid = process.pid;
          _unconfirmedProcesses[process.pid] = process;
          process.exitCode.then((_) {
            _unconfirmedProcesses.remove(process.pid);
          }, onError: (Object _) {});
        }
      }
      // Dispatch/deadline failure is uncertain even if no directory is visible
      // yet. Report its exact location, never replay mkdir or remove the path.
      throw HtmlExportFailure(
        destination,
        pendingDirectoryProcessId: pendingPid,
      );
    }
    if (directoryExit != 0) {
      throw StateError(
        'Could not exclusively create $destination; inspect it before retrying. '
        'Nothing was overwritten.',
      );
    }
    try {
      Future<void> checkDirectory(String directory) async {
        check();
        if (await Directory(directory).resolveSymbolicLinks() != directory ||
            await Directory(parent).resolveSymbolicLinks() != parent) {
          throw StateError('Export path changed.');
        }
        check();
      }

      await checkDirectory(destination);
      check();
      // Only the fixed template needs its one known subdirectory. Reviewed
      // proposals are restricted by their decoder to root-level source files.
      if (sources.containsKey('assets/mark.svg')) {
        await Directory(path.join(destination, 'assets')).create();
      }
      for (final entry in sources.entries) {
        await checkDirectory(destination);
        final file = File(path.join(destination, entry.key));
        await checkDirectory(file.parent.path);
        check();
        await file.create(exclusive: true);
        // Recheck following the async create before opening for content writes.
        await checkDirectory(file.parent.path);
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw StateError('Export file changed.');
        }
        check();
        await file.writeAsString(entry.value, flush: true);
      }
      await checkDirectory(destination);
      return destination;
    } catch (_) {
      // Never delete a path which another actor could have changed or report a
      // partially written directory as a successful, runnable project.
      throw HtmlExportFailure(destination);
    }
  }
}

// Keep uncertain process ownership across screen closure and reopening.
final _appExporter = HtmlSourceExportNative();
HtmlSourceExport createHtmlSourceExport() => _appExporter;

HtmlReviewedSourceExport createHtmlReviewedSourceExport() => _appExporter;

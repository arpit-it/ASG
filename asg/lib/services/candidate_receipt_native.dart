// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/agent_recovery_decision.dart';
import '../models/candidate_operation_receipt.dart';
import '../models/candidate_verification_run.dart';
import '../models/source_generation.dart';

/// App-owned evidence outside the inherited candidate write boundary.
/// This does not defend against another unrestricted process running as the user.
final class CandidateReceiptFiles {
  CandidateReceiptFiles({Future<Directory> Function()? root})
    : _root = root ?? _defaultRoot;
  final Future<Directory> Function() _root;

  static Future<Directory> _defaultRoot() async => Directory(
    path.join(
      (await getApplicationSupportDirectory()).path,
      'candidate-completion-receipts-v1',
    ),
  );

  String _prefix(String dispatch) =>
      '${sha256.convert(utf8.encode(dispatch))}-';
  String _hash(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  Map<String, Object?> _executionInputs(GeneratedProject snapshot) => {
    'directory': path.normalize(snapshot.directory),
    'sdk': path.normalize(snapshot.sdk),
    'python': snapshot.python,
    'confined': snapshot.confined,
    'checkpointVersion': snapshot.checkpointVersion,
    'sources': Map.fromEntries(
      snapshot.sources.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
    'approval': snapshot.approval?.toJson(),
    'limits': snapshot.limits.toJson(),
    'tasks': snapshot.tasks?.map((task) => task.toJson()).toList(),
  };

  /// Preparation must not be reused for a different source or execution scope.
  void requireSnapshot(
    CandidateVerificationRun run,
    GeneratedProject snapshot,
  ) {
    if (_hash(_executionInputs(run.snapshot)) !=
        _hash(_executionInputs(snapshot))) {
      throw StateError(
        'Prepared receipt inputs no longer match this verification.',
      );
    }
  }

  CandidateReceiptContext _context(CandidateVerificationRun run, String host) {
    final dispatch = run.dispatchId;
    final approval = run.snapshot.approval;
    if (dispatch == null ||
        approval == null ||
        !approval.approved ||
        !run.snapshot.confined) {
      throw StateError('Candidate receipt identity is unavailable.');
    }
    final sources = Map.fromEntries(
      run.snapshot.sources.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    );
    return CandidateReceiptContext(
      dispatchId: dispatch,
      sourceFingerprint: _hash(sources),
      approvalFingerprint: _hash(approval.toJson()),
      executionFingerprint: _hash(_executionInputs(run.snapshot)),
      hostSessionId: host,
    );
  }

  bool _overlaps(String first, String second) =>
      first == second ||
      path.isWithin(first, second) ||
      path.isWithin(second, first);

  Future<String> prepare(
    CandidateVerificationRun run,
    void Function() authorize,
  ) async {
    if (run.finished) {
      throw StateError('Completed checks cannot dispatch receipts.');
    }
    final random = Random.secure();
    final host = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final context = _context(run, host);
    final root = await _root();
    final candidate = await Directory(run.snapshot.directory)
        .resolveSymbolicLinks();
    final sdk = await Directory(run.snapshot.sdk).resolveSymbolicLinks();
    final parent = await root.parent.resolveSymbolicLinks();
    final candidateRoot = path.normalize(root.absolute.path);
    final cache = Directory(
      Platform.environment['PUB_CACHE'] ??
          path.join(Platform.environment['HOME'] ?? '', '.pub-cache'),
    );
    final cacheRoot = await cache.exists()
        ? await cache.resolveSymbolicLinks()
        : path.normalize(cache.absolute.path);
    if (parent != path.normalize(root.parent.absolute.path) ||
        _overlaps(candidateRoot, candidate) ||
        _overlaps(candidateRoot, sdk) ||
        _overlaps(candidateRoot, cacheRoot) ||
        await FileSystemEntity.type(root.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw StateError('Receipt storage overlaps or links execution roots.');
    }
    authorize();
    await root.create();
    final canonical = await root.resolveSymbolicLinks();
    if (canonical != path.normalize(root.absolute.path) ||
        _overlaps(canonical, candidate) ||
        _overlaps(canonical, sdk)) {
      throw StateError('Receipt storage overlaps candidate execution roots.');
    }
    if ((await _directories(root, context.dispatchId)).isNotEmpty) {
      throw StateError('Candidate receipt dispatch already reserved.');
    }
    authorize();
    // Temporary-directory defaults vary by host. Establish private permissions
    // before writing context, outside candidate and scratch profiles.
    final directory = await root.createTemp(_prefix(context.dispatchId));
    final permissions = await Process.run('/bin/chmod', [
      '700',
      directory.path,
    ]);
    if (permissions.exitCode != 0 ||
        (await directory.stat()).mode & 0x3f != 0) {
      throw StateError('Candidate receipt storage could not be made private.');
    }
    authorize();
    await File(path.join(directory.path, 'context.json'))
        .writeAsString(jsonEncode(context.toJson()), flush: true);
    authorize();
    return await directory.resolveSymbolicLinks();
  }

  Future<List<Directory>> _directories(Directory root, String dispatch) async {
    if (!await root.exists()) return [];
    if (await root.resolveSymbolicLinks() !=
        path.normalize(root.absolute.path)) {
      throw StateError('Linked candidate receipt storage refused.');
    }
    final entries = await root.list(followLinks: false).toList();
    final matches = entries
        .where((item) => path.basename(item.path).startsWith(_prefix(dispatch)))
        .toList();
    if (matches.any((item) => item is! Directory)) {
      throw StateError('Linked candidate receipt dispatch refused.');
    }
    final directories = matches.cast<Directory>();
    for (final directory in directories) {
      if ((await directory.stat()).mode & 0x3f != 0) {
        throw StateError('Candidate receipt dispatch is no longer private.');
      }
    }
    return directories;
  }

  Future<Object?> _read(File file, int limit) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() !=
            path.normalize(file.absolute.path)) {
      throw const FormatException('Invalid saved receipt file.');
    }
    final handle = await file.open();
    try {
      if (await handle.length() > limit) {
        throw const FormatException('Oversized saved receipt.');
      }
      final bytes = await handle.read(limit + 1);
      if (bytes.length > limit) {
        throw const FormatException('Oversized saved receipt.');
      }
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('Invalid saved receipt file.');
    } finally {
      await handle.close();
    }
  }

  Future<List<CandidateOperationReceipt>> read(
    CandidateVerificationRun run,
  ) async {
    if (run.dispatchId == null) return const [];
    final directories = await _directories(await _root(), run.dispatchId!);
    if (directories.isEmpty) return const [];
    if (directories.length != 1) {
      throw StateError('Ambiguous candidate receipt dispatch.');
    }
    final directory = directories.single;
    final saved = CandidateReceiptContext.fromJson(
      await _read(File(path.join(directory.path, 'context.json')), 4096),
    );
    if (!saved.matches(_context(run, saved.hostSessionId))) {
      throw StateError('Saved receipt does not match this check run.');
    }
    final receipts = <CandidateOperationReceipt>[];
    for (final operation in RecoveryOperation.values) {
      final result = File(
        path.join(directory.path, '${operation.name}.result.json'),
      );
      if (await FileSystemEntity.type(result.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        continue;
      }
      final intent = await _read(
        File(path.join(directory.path, '${operation.name}.intent.json')),
        4096,
      );
      if (intent is! Map<String, dynamic> ||
          intent.length != 3 ||
          intent['version'] is! int ||
          intent['version'] != 1 ||
          intent['operation'] != operation.name ||
          !saved.matches(CandidateReceiptContext.fromJson(intent['context']))) {
        throw const FormatException('Invalid saved receipt intent.');
      }
      final receipt = CandidateOperationReceipt.fromJson(
        await _read(result, 512 * 1024),
      );
      if (receipt.operation != operation || !saved.matches(receipt.context)) {
        throw const FormatException('Mismatched saved receipt result.');
      }
      receipts.add(receipt);
    }
    return List.unmodifiable(receipts);
  }
}
